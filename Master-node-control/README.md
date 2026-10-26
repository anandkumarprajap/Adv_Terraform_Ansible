```bash
cat hosts.ini
chmod 600 terra-key-ansible
ansible -i hosts.ini workers -m ping
ls
```

```json
worker-ubuntu | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
worker-amazon | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
worker-redhat | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```
