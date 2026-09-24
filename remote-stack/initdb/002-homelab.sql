--
-- Homelab setup for Guacamole, applied once when the database is first
-- created (after 001-guacamole-schema.sql, which is generated verbatim by
-- `guacamole/guacamole:1.6.0 /opt/guacamole/bin/initdb.sh --postgresql`).
--
-- Login is Authentik (OpenID) only. Guacamole trusts the "groups" claim in
-- Authentik's token: members of Authentik's "authentik Admins" group land
-- in the matching Guacamole user group below, which can administer
-- Guacamole and use the server's desktop connection. Authentik's
-- application policy (authentik/blueprints/remote-desktop.yaml) already
-- refuses everyone else before they ever reach Guacamole.
--

-- 1. Remove the stock admin account (guacadmin / guacadmin). Its password
--    is public knowledge, and Guacamole's /api/tokens endpoint accepts
--    database logins even when the login page redirects to Authentik.
DELETE FROM guacamole_entity WHERE name = 'guacadmin' AND type = 'USER';

-- 2. Admin group, named exactly like the Authentik group.
INSERT INTO guacamole_entity (name, type) VALUES ('authentik Admins', 'USER_GROUP');
INSERT INTO guacamole_user_group (entity_id)
    SELECT entity_id FROM guacamole_entity WHERE name = 'authentik Admins' AND type = 'USER_GROUP';

INSERT INTO guacamole_system_permission (entity_id, permission)
    SELECT entity_id, permission::guacamole_system_permission_type
    FROM guacamole_entity,
         (VALUES ('ADMINISTER'), ('CREATE_CONNECTION'), ('CREATE_CONNECTION_GROUP'),
                 ('CREATE_SHARING_PROFILE'), ('CREATE_USER'), ('CREATE_USER_GROUP')) AS p (permission)
    WHERE name = 'authentik Admins' AND type = 'USER_GROUP';

-- 3. The server's own Windows desktop over RDP. Username/password are left
--    blank on purpose: Guacamole asks for your Windows login each time, so
--    no Windows credential is ever stored here. NLA stays on (Windows'
--    own pre-login check); the certificate is Windows' self-signed one.
INSERT INTO guacamole_connection (connection_name, protocol) VALUES ('Server Desktop', 'rdp');

INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
    SELECT connection_id, parameter_name, parameter_value
    FROM guacamole_connection,
         (VALUES ('hostname', 'host.docker.internal'),
                 ('port', '3389'),
                 ('security', 'nla'),
                 ('ignore-cert', 'true'),
                 ('resize-method', 'display-update'),
                 ('enable-wallpaper', 'false'),
                 ('enable-font-smoothing', 'true'),
                 ('enable-drive', 'false'),
                 ('disable-copy', 'false'),
                 ('disable-paste', 'false')) AS p (parameter_name, parameter_value)
    WHERE connection_name = 'Server Desktop';

INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
    SELECT e.entity_id, c.connection_id, 'READ'::guacamole_object_permission_type
    FROM guacamole_entity e, guacamole_connection c
    WHERE e.name = 'authentik Admins' AND e.type = 'USER_GROUP' AND c.connection_name = 'Server Desktop';
