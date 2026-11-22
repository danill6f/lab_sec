FROM rockylinux:9

ARG LAB_USER=analista
ARG LAB_PASS=Lab@2026!
ARG ROOT_PASS=Root@2026!

RUN dnf -y install openssh-server openssh-clients sudo passwd procps-ng iproute \
        iputils net-tools vim-minimal less hostname \
    && dnf clean all \
    && ssh-keygen -A \
    && echo "root:${ROOT_PASS}" | chpasswd \
    && useradd -m -s /bin/bash -G wheel "${LAB_USER}" \
    && echo "${LAB_USER}:${LAB_PASS}" | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && rm -f /run/nologin

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
