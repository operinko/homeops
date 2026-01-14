# Tempest MCP Server

Custom MCP server for WeatherFlow Tempest weather data with native FastMCP StreamableHTTP support.

## Features

- **Native StreamableHTTP**: No Supergateway middleware required
- **Stateless HTTP mode**: Prevents session memory leaks
- **Cached responses**: 5-minute TTL to reduce API calls
- **Kubernetes-ready**: Health endpoint, non-root user

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WEATHERFLOW_API_TOKEN` | WeatherFlow API token (required) | - |
| `WEATHERFLOW_CACHE_TTL` | Cache timeout in seconds | 300 |
| `WEATHERFLOW_CACHE_SIZE` | Maximum cache entries | 100 |
| `PORT` | Server port | 8000 |
| `DEBUG` | Enable debug logging | false |

## MCP Tools

- `get_stations()` - List available weather stations
- `get_station(station_id)` - Get station details
- `get_observation(station_id)` - Current weather conditions
- `get_forecast(station_id)` - Weather forecast
- `clear_cache()` - Clear response cache

## Endpoints

- `GET /` - Server info
- `GET /healthz` - Health check
- `POST /mcp` - MCP StreamableHTTP endpoint

## Local Development

```bash
# Set API token
export WEATHERFLOW_API_TOKEN=your_token

# Run with uvicorn
python -m tempest_mcp.main
```

## Docker

```bash
docker build -t tempest-mcp .
docker run -p 8000:8000 -e WEATHERFLOW_API_TOKEN=your_token tempest-mcp
```
