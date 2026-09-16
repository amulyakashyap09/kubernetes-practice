
## containerd

- containerd is an industry-standard container runtime that provides the fundamental tools for running containers.
- Originally developed by Docker, containerd is now maintained by the CNCF and has become one of the most widely adopted container runtimes in the cloud-native ecosystem.
- containerd provides several essential services to Kubernetes:
    - **Container Lifecycle Management**: Creating, starting, stopping, and deleting containers
    - **Image Management**: Pulling, storing, and managing container images from registries
    - **Storage Management**: Handling container filesystems and volume mounts
    - **Network Management**: Coordinating with CNI plugins for container networking
    - **Runtime Management**: Interfacing with low-level runtimes

## containerd in k8s
![containerd-in-k8s.png](./assets/containerd-in-k8s.png)

### Download and install containerd:

#### Download and install containerd:

```
CONTAINERD_VERSION=2.2.1

curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION?}/containerd-${CONTAINERD_VERSION?}-linux-amd64.tar.gz"

sudo tar xzvofC "containerd-${CONTAINERD_VERSION?}-linux-amd64.tar.gz" /usr/local

```

#### Download the systemd unit file to run containerd as a systemd service:
```
sudo wget -P /etc/systemd/system "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION?}/containerd.service"

```

#### Start the containerd service:
```
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

```

### Interacting with conatinerd

- **containerd includes a CLI tool called ctr for basic container operations.**
```
sudo ctr images pull ghcr.io/sagikazarmark/docker-hello-world:latest
```
- With the image pulled, you can run the container:
```
sudo ctr run --rm ghcr.io/sagikazarmark/docker-hello-world:latest hello
```

### Installing an OCI Runtime

- **containerd** is a high-level container runtime that provides a wide range of container management services (like image management, storage, and networking), 
- but delegates certain tasks to specialized components. One such task is actually running the container process, which containerd delegates to a **low-level OCI runtime**.

![oci-containerd-in-k8s](./assets/oci-containerd-in-k8s.png)

- **Conatinerd-shim** - The containerd-shim is a lightweight process that acts as a **bridge** between **containerd and OCI runtimes**.
- It provides a **stable interface** for containerd **to interact with the runtime**, **keeps containers running even if containerd crashes, handles container I/O, and reaps processes when they exit**.

- **Runc** - runc is a CLI tool for spawning and running containers on Linux according to the OCI specification.

#### Download and install Runc:
```
RUNC_VERSION=v1.4.0

curl -fsSLO "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION?}/runc.amd64"

sudo install -m 755 runc.amd64 /usr/local/sbin/runc

```
#### Configure containerd to use the systemd cgroup driver with runc:

- Make the required directory (if not)
```
sudo mkdir -p /etc/containerd
sudoedit /etc/containerd/config.toml
```
- Configure the conatinerd to use systemd cground with runc
    - **cgroups (control groups)** limit and isolate resource usage (CPU, memory, I/O) for container processes.
    - When using systemd as the init system, it's recommended to use the systemd cgroup driver **so both systemd and the container runtime manage cgroups consistently.**
    - This **ensures the container runtime and systemd coordinate through a single cgroup hierarchy, rather than managing resources separately, which can cause instability under memory or CPU pressure**.
```
version = 3

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
SystemdCgroup = true
```

- Restart the containerd
```
sudo systemctl restart containerd
```

- Run the conatiner now:
```
sudo ctr run --rm ghcr.io/sagikazarmark/docker-hello-world:latest hello
```

### Interacting with NerdCtl

#### Download and install nerdctl:

```
NERDCTL_VERSION=2.2.1

curl -fsSLO "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION?}/nerdctl-${NERDCTL_VERSION?}-linux-amd64.tar.gz"

tar xzvof "nerdctl-${NERDCTL_VERSION?}-linux-amd64.tar.gz"

sudo install -m 755 nerdctl /usr/local/bin

nerdctl completion bash | sudo tee /etc/bash_completion.d/nerdctl

```
#### Verify by running container

```
sudo nerdctl run --rm ghcr.io/stefanprodan/podinfo:latest /home/app/podinfo --version
```

**Above will fail with an error**
```
FATA[0005] failed to verify networking settings: failed to create default network: needs CNI plugin "bridge" to be installed in CNI_PATH ("/opt/cni/bin"), see https://github.com/containernetworking/plugins/releases: exec: "/opt/cni/bin/bridge": stat /opt/cni/bin/bridge: no such file or directory 
laborant@ubuntu-01:~$ 
```

#### Temporary Workaround

**Never try in production always use CNI plugins**

```
sudo nerdctl run --net host --rm ghcr.io/stefanprodan/podinfo:latest /home/app/podinfo --version
```

### Installing CNI Plugins

![oci-containerd-in-k8s](./assets/cni-oci-containerd-in-k8s.png)

#### Download and install CNI plugins:
```
CNI_PLUGINS_VERSION=v1.9.0

curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION?}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION?}.tgz"

sudo mkdir -p /opt/cni/bin

sudo tar xzvofC "cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION?}.tgz" /opt/cni/bin
```

- Above 💡 CNI plugins are installed in `/opt/cni/bin` by convention.
- Container runtimes and Kubernetes network add-ons look for them in this directory by default.
---

#### Run the container again using nerdctl:
```
sudo nerdctl run -d --name podinfo ghcr.io/stefanprodan/podinfo:latest
```

#### Verify that the container is running:
```
sudo nerdctl ps
```

#### Verify that podinfo is working correctly:

```
PODINFO_IP=$(sudo nerdctl inspect --format '{{ .NetworkSettings.IPAddress }}' podinfo)
curl -f "http://${PODINFO_IP}:9898"
```

## Glossary:
- CTR 
    - Containerd includes a CLI tool called ctr for basic container operations. 
    - An excellent tool for low-level interaction with containerd, it isn't the most user-friendly tool, especially for users familiar with the Docker CLI.
    - Unlike ctr, nerdctl automatically handles image pulling and network setup.
- Nerdctl
    - While ctr doesn't automatically create a network for containers, nerdctl attempts to create a bridge network by default.



