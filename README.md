Kong Custom Rate Limiting Plugin
=================================

This repository contains a custom rate limiting plugin for Kong Gateway.

This plugin is designed to work with Kong Gateway and follows the standard
Kong plugin development practices. For installation and distribution instructions,
please refer to the [Kong documentation on custom plugins](https://developer.konghq.com/custom-plugins/installation-and-distribution/).

* *Kong plugin name*: `custom-rate-limiting`

* *Kong plugin version*: `0.1.0` (set in the `VERSION` field inside `handler.lua`)

This results in:

* *LuaRocks package name*: `kong-plugin-custom-rate-limiting`

* *LuaRocks package version*: `0.1.0`

* *LuaRocks rockspec revision*: `1`

* *rockspec file*: `kong-plugin-custom-rate-limiting-0.1.0-1.rockspec`

* File *`handler.lua`* is located at: `./kong/plugins/custom-rate-limiting/handler.lua` (and similar for the other plugin files)

Installation
------------

### Standard Kong Gateway Installation

To install this plugin, follow the instructions in the [Kong documentation on custom plugins](https://developer.konghq.com/custom-plugins/installation-and-distribution/).

Quick start with LuaRocks:

```bash
luarocks make
```

Then add the plugin to your Kong configuration:

```
plugins = bundled,custom-rate-limiting
```

Restart Kong Gateway to load the plugin.

### Kong Ingress Controller Installation

To integrate this plugin with Kong Ingress Controller (KIC) in Kubernetes, follow these steps:

#### 1. Package Your Plugin

First, ensure your plugin is packaged correctly. If you're using LuaRocks, create a `.rockspec` file (already included in this repository).

#### 2. Build Custom Docker Image

Create a Dockerfile that includes your custom plugin. This approach packages the plugin directly into the Kong Gateway image:

**Dockerfile:**

```dockerfile
FROM kong/kong-gateway:latest

# Ensure any patching steps are executed as root user
USER root

# Copy custom plugin to the Kong plugins directory
COPY kong/plugins/custom-rate-limiting /usr/local/share/lua/5.1/kong/plugins/custom-rate-limiting

# Set environment variable to enable the plugin
ENV KONG_PLUGINS=bundled,custom-rate-limiting

# Ensure kong user is selected for image execution
USER kong

# Run kong
ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 8000 8443 8001 8444
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health
CMD ["kong", "docker-start"]
```

Build and push the Docker image:

```bash
# Build the image
docker build -t your-registry/kong-gateway-custom-rate-limiting:latest .

# Push to your container registry
docker push your-registry/kong-gateway-custom-rate-limiting:latest
```

#### 3. Configure Kong Ingress Controller

Modify your Helm `values.yaml` to use your custom image:

```yaml
# Use your custom Kong Gateway image
image:
  repository: your-registry/kong-gateway-custom-rate-limiting
  tag: latest

# Enable the plugin in Kong configuration
env:
  plugins: bundled,custom-rate-limiting
```

Then install or upgrade the Kong Ingress Controller:

```bash
helm repo add kong https://charts.konghq.com
helm repo update
helm install kong kong/ingress -n kong --create-namespace --values values.yaml
```

Or if upgrading:

```bash
helm upgrade kong kong/ingress -n kong --values values.yaml
```

#### 4. Create KongPlugin Resources

Define `KongPlugin` custom resources to configure your plugin. Here are some example configurations:

**Basic Rate Limiting (per consumer):**

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: custom-rate-limiting-basic
config:
  minute: 100
  hour: 1000
  limit_by: consumer
  policy: local
plugin: custom-rate-limiting
```

**Rate Limiting by IP:**

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: custom-rate-limiting-by-ip
config:
  second: 10
  minute: 100
  hour: 1000
  limit_by: ip
  policy: local
  error_code: 429
  error_message: "Rate limit exceeded. Please try again later."
plugin: custom-rate-limiting
```

**Rate Limiting with Redis (for distributed deployments):**

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: custom-rate-limiting-redis
config:
  minute: 100
  hour: 1000
  day: 10000
  limit_by: consumer
  policy: redis
  redis:
    host: redis-service
    port: 6379
    password: your-redis-password
    database: 0
    timeout: 2000
    ssl: false
  fault_tolerant: true
  sync_rate: 0.1
plugin: custom-rate-limiting
```

**Rate Limiting with IP Whitelist:**

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: custom-rate-limiting-whitelist
config:
  minute: 50
  hour: 500
  limit_by: ip
  policy: local
  white_listed_ips:
    - "10.0.0.0/8"
    - "192.168.1.1"
    - "172.16.0.0/12"
plugin: custom-rate-limiting
```

**Rate Limiting by Header:**

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: custom-rate-limiting-by-header
config:
  minute: 200
  hour: 2000
  limit_by: header
  header_name: X-API-Key
  policy: local
plugin: custom-rate-limiting
```

Apply the KongPlugin configuration:

```bash
kubectl apply -f custom-rate-limiting-plugin.yaml
```

#### 5. Apply Plugin to Ingress Resources

Link the `KongPlugin` to your Ingress resource by adding an annotation:

**Using Ingress annotation:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-api-ingress
  annotations:
    konghq.com/plugins: custom-rate-limiting-basic
spec:
  ingressClassName: kong
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-api-service
            port:
              number: 80
```

**Using IngressClass parameters:**

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: kong
spec:
  controller: ingress-controllers.konghq.com/kong
  parameters:
    apiGroup: configuration.konghq.com
    kind: KongIngressClass
    name: default
---
apiVersion: configuration.konghq.com/v1
kind: KongIngressClass
metadata:
  name: default
plugins:
- custom-rate-limiting-basic
```

**Using KongIngress resource:**

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongIngress
metadata:
  name: my-api-kong-ingress
plugins:
- custom-rate-limiting-basic
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-api-ingress
  annotations:
    konghq.com/override: my-api-kong-ingress
spec:
  ingressClassName: kong
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-api-service
            port:
              number: 80
```

**Using Service annotation:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-api-service
  annotations:
    konghq.com/plugins: custom-rate-limiting-basic
spec:
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: my-api
```

#### 6. Verify Plugin Configuration

Check that the plugin is loaded:

```bash
# Check Kong pods
kubectl get pods -n kong

# Check plugin configuration in Kong
kubectl exec -it -n kong <kong-pod-name> -- kong config parse

# View plugin logs
kubectl logs -n kong <kong-pod-name> | grep custom-rate-limiting
```

#### Configuration Options

The plugin supports the following configuration options:

- **Rate Limits**: `second`, `minute`, `hour`, `day`, `month`, `year` (at least one required)
- **limit_by**: `consumer`, `credential`, `ip`, `service`, `header`, `path` (default: `consumer`)
- **policy**: `local`, `cluster`, `redis` (default: `local`)
- **header_name**: Required when `limit_by` is `header`
- **path**: Required when `limit_by` is `path`
- **redis**: Redis configuration object (required when `policy` is `redis`)
  - `host`: Redis hostname
  - `port`: Redis port
  - `password`: Redis password (optional)
  - `username`: Redis username (optional)
  - `database`: Redis database number (default: 0)
  - `timeout`: Connection timeout in milliseconds
  - `ssl`: Enable SSL (default: false)
  - `ssl_verify`: Verify SSL certificate (default: false)
  - `server_name`: SSL server name for SNI
- **fault_tolerant**: Allow requests even if data store is unavailable (default: `true`)
- **hide_client_headers**: Hide rate limit headers in responses (default: `false`)
- **error_code**: HTTP status code when limit exceeded (default: `429`)
- **error_message**: Custom error message (default: `"API rate limit exceeded"`)
- **sync_rate**: How often to sync counters to Redis (default: `-1` for synchronous)
- **white_listed_ips**: Array of IPs or CIDR ranges to exclude from rate limiting

For more information, refer to the [Kong Ingress Controller documentation on custom plugins](https://docs.konghq.com/kubernetes-ingress-controller/latest/plugins/custom/).
