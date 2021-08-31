FROM alpine:3.12

RUN apk add --update 'mariadb-client>10.3.15' mariadb-connector-c bash python3 samba-client shadow openssl cmd:pip3 && \
    rm -rf /var/cache/apk/* && \
    touch /etc/samba/smb.conf && \
    pip3 install awscli

COPY scripts/ /usr/local/bin/

#RUN groupadd -g 1005 liferay && \
#    useradd -r -u 1005 -g liferay liferay

RUN adduser -D -h /home/liferay liferay && addgroup liferay liferay

RUN mkdir -p /var/cache/samba && \
    chmod 0755 /var/cache/samba && \
    chown liferay /var/cache/samba && \
    mkdir -p /home/liferay/portal_backup && \
    chown -R liferay:liferay /home/liferay/portal_backup

#    rm -rf /var/backups/portal_backup && \
#    mkdir -p /var/backups/portal_backup && \
#    chown liferay /var/backups/portal_backup && \
#    chmod 0755 /var/backups/portal_backup


VOLUME /home/liferay/portal_backup

USER liferay:liferay

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["backup"]
