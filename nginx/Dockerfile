FROM nginx:stable

ARG LAB_USER=analista
ARG LAB_PASS=Lab@2026!
ARG ROOT_PASS=Root@2026!

RUN echo "root:${ROOT_PASS}" | chpasswd \
    && useradd -m -s /bin/bash "${LAB_USER}" \
    && echo "${LAB_USER}:${LAB_PASS}" | chpasswd

EXPOSE 80
