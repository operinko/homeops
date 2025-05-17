// Copyright 2018 Intel Corporation. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Package patcher provides functionality required to patch pods by the FPGA admission webhook.
package patcher

import (
	"bytes"
	"fmt"
	"strings"
	"sync"
	"text/template"

	"github.com/go-logr/logr"
	"github.com/pkg/errors"

	corev1 "k8s.io/api/core/v1"

	fpgav2 "github.com/intel/intel-device-plugins-for-kubernetes/pkg/apis/fpga/v2"
	"github.com/intel/intel-device-plugins-for-kubernetes/pkg/fpga"
	"github.com/intel/intel-device-plugins-for-kubernetes/pkg/internal/containers"
)

const (
	namespace = "fpga.intel.com"

	af     = "af"
	region = "region"
	// "regiondevel" corresponds to the FPGA plugin's regiondevel mode. It requires
	// FpgaRegion CRDs to be added to the cluster.
	regiondevel = "regiondevel"

	resourceRemoveOp = `{
                "op": "remove",
                "path": "/spec/containers/%d/resources/%s/%s"
        }`
	resourceAddOp = `{
                "op": "add",
                "path": "/spec/containers/%d/resources/%s/%s",
                "value": "%d"
        }`
	envAddOpTpl = `{
                "op": "add",
                "path": "/spec/containers/{{- .ContainerIdx -}}/env",
                "value": [
                     {{- $first := true -}}
                     {{- range $key, $value := .EnvVars -}}
                       {{- if not $first -}},{{- end -}}{
                          "name": "{{$key}}",
                          "value": "{{$value}}"
                       }
                       {{- $first = false -}}
                     {{- end -}}
                ]
        }`
)

var (
	rfc6901Escaper = strings.NewReplacer("~", "~0", "/", "~1")
)

// Patcher stores FPGA controller's state.
//
//nolint:govet
type Patcher struct {
	sync.Mutex

	log logr.Logger

	afMap           map[string]*fpgav2.AcceleratorFunction
	resourceMap     map[string]string
	resourceModeMap map[string]string

	// This set is needed to maintain the webhook's idempotence: it must be possible to
	// resolve actual resources (AFs and regions) to themselves. For this we build
	// a set of identities which must be accepted by the webhook without any transformation.
	identitySet map[string]int
}

func newPatcher(log logr.Logger) *Patcher {
	return &Patcher{
		log:             log,
		afMap:           make(map[string]*fpgav2.AcceleratorFunction),
		resourceMap:     make(map[string]string),
		resourceModeMap: make(map[string]string),
		identitySet:     make(map[string]int),
	}
}

func (p *Patcher) incIdentity(id string) {
	// Initialize to 1 or increment by 1.
	p.identitySet[id] = p.identitySet[id] + 1
}

func (p *Patcher) decIdentity(id string) {
	counter := p.identitySet[id]
	if counter > 1 {
		p.identitySet[id] = counter - 1
	} else {
		delete(p.identitySet, id)
	}
}

func (p *Patcher) AddAf(accfunc *fpgav2.AcceleratorFunction) error {
	defer p.Unlock()
	p.Lock()

	p.afMap[namespace+"/"+accfunc.Name] = accfunc

	if accfunc.Spec.Mode == af {
		devtype, err := fpga.GetAfuDevType(accfunc.Spec.InterfaceID, accfunc.Spec.AfuID)
		if err != nil {
			return err
		}

		mapping := rfc6901Escaper.Replace(namespace + "/" + devtype)
		p.resourceMap[namespace+"/"+accfunc.Name] = mapping
		p.incIdentity(mapping)
	} else {
		mapping := rfc6901Escaper.Replace(namespace + "/region-" + accfunc.Spec.InterfaceID)
		p.resourceMap[namespace+"/"+accfunc.Name] = mapping
		p.incIdentity(mapping)
	}

	p.resourceModeMap[namespace+"/"+accfunc.Name] = accfunc.Spec.Mode

	return nil
}

func (p *Patcher) AddRegion(region *fpgav2.FpgaRegion) {
	defer p.Unlock()
	p.Lock()

	p.resourceModeMap[namespace+"/"+region.Name] = regiondevel
	mapping := rfc6901Escaper.Replace(namespace + "/region-" + region.Spec.InterfaceID)
	p.resourceMap[namespace+"/"+region.Name] = mapping
	p.incIdentity(mapping)
}

func (p *Patcher) RemoveAf(name string) {
	defer p.Unlock()
	p.Lock()

	nname := namespace + "/" + name

	p.decIdentity(p.resourceMap[nname])
	delete(p.afMap, nname)
	delete(p.resourceMap, nname)
	delete(p.resourceModeMap, nname)
}

func (p *Patcher) RemoveRegion(name string) {
	defer p.Unlock()
	p.Lock()

	nname := namespace + "/" + name

	p.decIdentity(p.resourceMap[nname])
	delete(p.resourceMap, nname)
	delete(p.resourceModeMap, nname)
}

// sanitizeContainer filters out env variables reserved for CRI hook.
func sanitizeContainer(container corev1.Container) corev1.Container {
	i := 0

	// Rewrite container.Env slice in-place to avoid memory allocations.
	for _, v := range container.Env {
		if !(strings.HasPrefix(v.Name, "FPGA_REGION") || strings.HasPrefix(v.Name, "FPGA_AFU")) {
			container.Env[i] = v
			i++
		}
	}

	// Erase truncated elements.
	if i == 0 {
		container.Env = nil
	} else {
		container.Env = container.Env[:i]
	}

	return container
}

func (p *Patcher) getNoopsOrError(name string) ([]string, error) {
	if _, isVirtual := p.identitySet[rfc6901Escaper.Replace(name)]; isVirtual {
		// `name` is not a real mapping, but a virtual one for an actual resource which
		// needs to be resolved to itself with no transformations.
		return []string{}, nil
	}

	return nil, errors.Errorf("no such resource: %q", name)
}

func (p *Patcher) getPatchOps(containerIdx int, container corev1.Container) ([]string, error) {
	container = sanitizeContainer(container)

	requestedResources, err := containers.GetRequestedResources(container, namespace)
	if err != nil {
		return nil, err
	}

	defer p.Unlock()
	p.Lock()

	fpgaPluginMode := ""
	resources := make(map[string]int64)
	envVars := make(map[string]string)
	counter := 0
	ops := make([]string, 0, 2*len(requestedResources))

	for rname, quantity := range requestedResources {
		mode, found := p.resourceModeMap[rname]
		if !found {
			return p.getNoopsOrError(rname)
		}

		switch mode {
		case regiondevel, af:
			// Do nothing.
			// The requested resources are exposed by FPGA plugins working in "regiondevel/af" mode.
			// In "regiondevel" mode the workload is supposed to program FPGA regions.
			// A cluster admin has to add FpgaRegion CRDs to allow this.
		case region:
			// Let fpga_crihook know how to program the regions by setting ENV variables.
			// The requested resources are exposed by FPGA plugins working in "region" mode.
			for i := int64(0); i < quantity; i++ {
				counter++

				envVars[fmt.Sprintf("FPGA_REGION_%d", counter)] = p.afMap[rname].Spec.InterfaceID
				envVars[fmt.Sprintf("FPGA_AFU_%d", counter)] = p.afMap[rname].Spec.AfuID
			}
		default:
			// Let admin know about broken af CRD.
			err := errors.Errorf("%q is registered with unknown mode %q instead of %q or %q",
				rname, p.resourceModeMap[rname], af, region)
			p.log.Error(err, "unable to construct patching operations")

			return nil, err
		}

		if fpgaPluginMode == "" {
			fpgaPluginMode = mode
		} else if fpgaPluginMode != mode {
			return nil, errors.New("container cannot be scheduled as it requires resources operated in different modes")
		}

		mappedName := p.resourceMap[rname]
		resources[mappedName] = resources[mappedName] + quantity

		// Add operations to remove unresolved resources from the pod.
		ops = append(ops, fmt.Sprintf(resourceRemoveOp, containerIdx, "limits", rfc6901Escaper.Replace(rname)))
		ops = append(ops, fmt.Sprintf(resourceRemoveOp, containerIdx, "requests", rfc6901Escaper.Replace(rname)))
	}

	// Add operations to add resolved resources to the pod.
	for resource, quantity := range resources {
		op := fmt.Sprintf(resourceAddOp, containerIdx, "limits", resource, quantity)
		ops = append(ops, op)
		op = fmt.Sprintf(resourceAddOp, containerIdx, "requests", resource, quantity)
		ops = append(ops, op)
	}

	// Add the ENV variables to the pod if needed.
	if len(envVars) > 0 {
		for _, envvar := range container.Env {
			envVars[envvar.Name] = envvar.Value
		}

		data := struct {
			EnvVars      map[string]string
			ContainerIdx int
		}{
			ContainerIdx: containerIdx,
			EnvVars:      envVars,
		}

		t := template.Must(template.New("add_operation").Parse(envAddOpTpl))
		buf := new(bytes.Buffer)

		if err := t.Execute(buf, data); err != nil {
			return nil, errors.Wrap(err, "unable to execute template")
		}

		ops = append(ops, buf.String())
	}

	return ops, nil
}
