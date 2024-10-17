# Deploying agent-mode on a Lima VM

1. Ensure you have `lima` installed. If not, follow the instructions [here](https://lima-vm.io/docs/installation/)
2. Install `socket_vmnet`. Follow the instructions [here](https://lima-vm.io/docs/config/network/#socket_vmnet)
3. Download [lima.yaml](lima.yaml) and modify this line to your userdata path. It can be an URL or a file path.

```bash
export USERDATA=<path-to-your-userdata>
```

4. Create and start the VM

```bash
limactl create --name spectro-agent-mode lima.yaml
limactl start spectro-agent-mode
```

5. That's it! You can now shell into the VM

```bash
limactl shell spectro-agent-mode
```
