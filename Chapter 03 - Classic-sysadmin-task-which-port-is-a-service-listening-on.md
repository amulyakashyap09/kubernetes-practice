
# Challenge 3: Classic Sysadmin Task: Which Port Is a Service Listening On?

You have access to a Linux server running several services, including one named app. Your objective is to identify the port that the app service is using. This is an easy problem, but proceed with caution - you have only one attempt to submit your answer.

Good luck!

# Solution

You should inspect the running services rather than guess. Any of these commands will reveal the listening port(s):

```bash
sudo systemctl status app
```

If that doesn't show the port, check the listening sockets:

```bash
sudo ss -ltnp
```

or filter for the service:

```bash
sudo ss -ltnp | grep app
```

You can also inspect the process:

```bash
ps -ef | grep app
```

and, if you know its PID:

```bash
sudo lsof -Pan -p <PID> -i
```

or search the service definition:

```bash
sudo systemctl cat app
```

or

```bash
grep -R "ExecStart" /etc/systemd/system /lib/systemd/system | grep app
```

Since you have **only one submission attempt**, don't guess. Run:

```bash
sudo ss -ltnp
```

and look for a line like:

```text
LISTEN 0 128 0.0.0.0:PORT ...
```

where the process is `app`. The `PORT` value is your answer.
