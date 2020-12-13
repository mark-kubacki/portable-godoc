# Godoc and the Playground for systemd

Does neither need Docker nor Kubernetes,  
for when you are one the road, offline, or behind picky corporate firewalls.

## Setup
### On Debian, Ubuntu; as *.deb
Download and `apt-get install` one of the `*.deb` files
you can find under **releases**. Then, as `root`:

```bash
systemctl start \
  godoc-actual.socket \
  godoc-builder.socket \
  godoc-runner.socket
```

**Godoc** will be available on port 6060.
Try http://localhost:6060/

### Other Distributions
Extract any `*.deb` file like this (replace `-t` by `-x`):

```bash
ar x godoc_*.deb
tar -tavf data.tar.*
```

## On-Demand Activation
After some minutes without any new connections, *godoc.service* will exit
if it had been *socket-activated* by *systemd*.
Don't worry, that's intentional; it'll start again on demand,
on any new and first incoming connection to aforementioned port 6060.

## Runtime Environment
Although the *builder* and custom *runner* will run as `DynamicUser`,
to examples it might appear they're run as `UID=0`, i. e. `root`
due to some fancy namespacing to actually standardize that *UID*.

They're not run as isolated from the host system as by the original *playground*,
in containers or Kubernetes, which might exactly be what you or I want
on our private machines. For example, to call binaries from and interact
with the host system to test things otherwise not available there.

If you want examples to experience a *fixed time*, you will need to
compile a **go-faketime** yourself and copy it to `/usr/local/go-faketime`.
