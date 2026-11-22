FROM ubuntu:24.04

ARG LAB_USER=analista
ARG LAB_PASS=Lab@2026!
ARG ROOT_PASS=Root@2026!
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server sudo procps \
        iproute2 iputils-ping net-tools vim-tiny less ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && echo "root:${ROOT_PASS}" | chpasswd \
    && useradd -m -s /bin/bash -G sudo "${LAB_USER}" \
    && echo "${LAB_USER}:${LAB_PASS}" | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
