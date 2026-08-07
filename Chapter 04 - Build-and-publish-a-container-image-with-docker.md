# Challenge: Build and Publish a Container Image With Docker

# Solution

You just need to **build**, **login**, and **push** the image.

### 1. Change to the project directory

```bash
cd ~/projects/foobar
```

### 2. Build the image

```bash
docker build -t registry.iximiuz.com/foobar:v1.0.0 .
```

### 3. Log in to the registry

Using the recommended `--password-stdin` approach:

```bash
echo 'rules!' | docker login registry.iximiuz.com \
  --username iximiuzlabs \
  --password-stdin
```

Or interactively:

```bash
docker login registry.iximiuz.com
```

* Username: `iximiuzlabs`
* Password: `rules!`

### 4. Push the image

```bash
docker push registry.iximiuz.com/foobar:v1.0.0
```

### 5. Verify (optional)

```bash
docker images | grep foobar
```

You should see something similar to:

```text
registry.iximiuz.com/foobar   v1.0.0   <IMAGE_ID>
```

If the push fails, check:

* Docker daemon is running: `docker info`
* Login succeeded: `docker login registry.iximiuz.com`
* Image exists locally: `docker images`
* The tag is exactly:

  ```
  registry.iximiuz.com/foobar:v1.0.0
  ```