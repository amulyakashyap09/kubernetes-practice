# Challenge: Copy Files To/From a Running Kubernetes Pod: a Simple Case

Use `kubectl cp` to copy files into and out of the running Pod. Since the Pod should **not** be restarted, this is the correct approach.

### 1. Copy `nginx.conf` into the Pod

```bash
kubectl cp ~/nginx.conf default/web:/etc/nginx/nginx.conf -c server
```

### 2. Reload the Nginx configuration

```bash
kubectl exec web -c server -- nginx -s reload
```

### 3. Copy the Nginx binary from the Pod to the host

```bash
kubectl cp default/web:/usr/sbin/nginx ~/nginx-bin -c server
```

### (Optional) Verify

Check that the binary was copied:

```bash
ls -l ~/nginx-bin
```

Or verify Nginx is serving the updated config (replace `<POD_IP>` with the Pod's IP):

```bash
kubectl get pod web -o wide
curl http://<POD_IP>:80
```

These three commands are all that's required:

```bash
kubectl cp ~/nginx.conf default/web:/etc/nginx/nginx.conf -c server
kubectl exec web -c server -- nginx -s reload
kubectl cp default/web:/usr/sbin/nginx ~/nginx-bin -c server
```
