# The relay (EMQX) container per ADR 0006 - runs on the Compute Engine
# VM described there. Scope is deliberately just the broker: MQTT over
# WebSocket, credentialed access, and topic ACL per ADR 0001 and
# docs/spec/architecture.md's "MQTT topic design". Wiring
# packages/relay-core's decision logic into a live subscriber on this
# broker is out of scope - see docs/handoffs/80.md.
FROM emqx/emqx:5.8.0

# Baked-in, non-secret configuration: listeners, auth backend wiring,
# and the topic ACL. The one thing that is NOT baked in is the relay
# credential itself - see docker-entrypoint-relay.sh.
COPY --chmod=0644 emqx.conf /opt/emqx/etc/emqx.conf
COPY --chmod=0644 acl.conf /opt/emqx/etc/acl.conf
COPY --chmod=0755 docker-entrypoint-relay.sh /opt/emqx/docker-entrypoint-relay.sh

ENTRYPOINT ["/opt/emqx/docker-entrypoint-relay.sh"]
CMD ["/opt/emqx/bin/emqx", "foreground"]
