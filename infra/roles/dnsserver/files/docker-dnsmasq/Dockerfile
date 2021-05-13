FROM alpine:3.13
LABEL maintainer "Stijn Hoop <stijn@sandcat.nl>"
RUN apk --no-cache add dnsmasq
RUN mkdir -p /config
VOLUME /config
EXPOSE 53 53/udp
ENTRYPOINT ["dnsmasq", "-d", "-C", "/config/dnsmasq.conf"]
