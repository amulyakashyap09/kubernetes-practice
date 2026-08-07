# Challenge

A pre-built HTTP server binary has been placed on this machine at `/usr/local/bin/simple-server`. It listens on port `8080` and, when run, stays in the foreground until it's killed:

```
/usr/local/bin/simple-server

```

Copy to clipboard

Running it straight from the shell works, but it's fragile - closing the terminal kills it, a crash leaves nothing behind to bring it back, and it won't come up after a reboot. That's exactly what **systemd** can help with.

## Your task

Wrap the `simple-server` binary into a systemd service named `simple-server.service` so that:

1. The unit file lives at `/etc/systemd/system/simple-server.service`.
2. It runs `/usr/local/bin/simple-server` as its main process.
3. It is **enabled** (starts automatically after a reboot).
4. It is **currently active** and serving requests on port `8080`.
5. It is **automatically restarted** when its process terminates abnormally.

A minimal systemd service unit has three sections:

- `[Unit]` - human-readable description and ordering hints (e.g., `After=`).
- `[Service]` - how to start the process: `ExecStart=`, restart policy, user, etc.
- `[Install]` - where to hook the unit when it gets enabled (usually `WantedBy=multi-user.target`).

Refer to `man systemd.service` and `man systemd.unit` for the full list of available directives.


# Solution

## Points to note:
- Service should be able to recover if killed (ex: using `sudo kill -9 $(pgrep -f simple-server)`)
- Service should be able to automatically start if system rebooted (ex: `sudo reboot`)

### Definitions

#### Anatomy of a Service Unit File

A minimal systemd service unit has three sections:

- [Unit] - human-readable description and ordering hints (e.g., After=).
- [Service] - how to start the process: ExecStart=, restart policy, user, etc.
- [Install] - where to hook the unit when it gets enabled (usually WantedBy=multi-user.target).
Refer to man systemd.service and man systemd.unit for the full list of available directives.

### Step 1: Create `/etc/systemd/system/simple-server.service`

```
sudo vim /etc/systemd/system/simple-server.service
```

```
[Unit]
Description=Simple Http Server
After=network.target

[Service]
Type=Simple
ExecStart=/usr/local/bin/simple-server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Step 2: Reload the systemd daemon

```
sudo systemctl daemon-reload
```

### Step 3: Enable the service to start on boot

```
sudo systemctl enable simple-server.service
```

### Step 4: Start the service

```
sudo systemctl start simple-server.service
```

### Step 5: Verify it is active

```
sudo systemctl status simple-server.service
```

### Step 6: Verify it is enabled

```
sudo systemctl is-enabled simple-server.service
```

### Step 7: Verify it is listening on port 8080

```
sudo ss -ltnp | grep :8080
```
OR
```
curl http://localhost:8080
```

