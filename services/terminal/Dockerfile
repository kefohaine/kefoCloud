FROM tsl0922/ttyd:latest

# Helper: run host binaries (glibc) from inside this Alpine (musl) container.
# The container bind-mounts the host root at /host; host binaries need
# glibc and the host's dynamic linker, neither of which the Alpine base
# provides. `host-exec /host` is just `chroot` to the host's rootfs,
# which the kernel honors natively since /host is a bind mount.
RUN cat > /usr/local/bin/host-exec <<'EOF'
#!/bin/sh
exec /usr/sbin/chroot /host /bin/sh -c "$*"
EOF
RUN chmod +x /usr/local/bin/host-exec
