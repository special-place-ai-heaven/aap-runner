FROM scratch
COPY srv /srv
# exec form: there is no shell in the image (docker run --health-cmd would need /bin/sh)
HEALTHCHECK --interval=1s --retries=30 CMD ["/srv", "fetch", "127.0.0.1", "8080"]
ENTRYPOINT ["/srv"]
