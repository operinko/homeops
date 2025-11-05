#!/usr/bin/env python3
"""Extract Helm values from ArgoCD Application YAML files."""

import yaml
from pathlib import Path

apps = [
    "configarr", "huntarr", "prowlarr", "radarr", "readarr",
    "sabnzbd", "sonarr", "spotarr", "taggarr", "tautulli",
    "tvheadend", "wizarr"
]

base_dir = Path("kubernetes/argocd/applications/media")
apps_dir = base_dir / "apps"

for app in apps:
    print(f"Processing {app}...")
    
    app_yaml = base_dir / f"{app}.yaml"
    values_yaml = apps_dir / app / "values.yaml"
    
    if not app_yaml.exists():
        print(f"  ⚠ {app_yaml} not found")
        continue
    
    # Load the Application YAML
    with open(app_yaml, 'r') as f:
        app_data = yaml.safe_load(f)
    
    # Extract valuesObject from spec.source.helm.valuesObject
    try:
        values = app_data['spec']['source']['helm']['valuesObject']
        
        # Write values.yaml
        with open(values_yaml, 'w') as f:
            f.write("---\n")
            f.write(f"# Helm values for {app} app-template deployment\n")
            yaml.dump(values, f, default_flow_style=False, sort_keys=False)
        
        print(f"  ✓ Created {values_yaml}")
    except (KeyError, TypeError) as e:
        print(f"  ⚠ Could not extract values: {e}")

print("\nDone!")

