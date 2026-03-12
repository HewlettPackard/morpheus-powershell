@{
    default = @{
        list = @('id', 'name', 'status', 'type')
        detail = @('id', 'name', 'status', 'type', 'description', 'code', 'dateCreated', 'lastUpdated', 'uuid')
    }

    instances = @{
        list = @('id', 'name', 'status', 'powerState', 'instanceType', 'plan')
        detail = @('id', 'name', 'displayName', 'status', 'powerState', 'instanceType', 'plan', 'createdBy', 'dateCreated', 'lastUpdated', 'uuid')
    }

    servers = @{
        list = @('id', 'name', 'status', 'powerState', 'hostname', 'internalIp')
        detail = @('id', 'name', 'displayName', 'status', 'powerState', 'hostname', 'internalIp', 'externalIp', 'plan', 'createdBy', 'dateCreated', 'lastUpdated', 'uuid')
    }

    groups = @{
        list = @('id', 'name', 'code', 'location')
        detail = @('id', 'name', 'code', 'location', 'zonePools', 'visibility', 'active', 'dateCreated', 'lastUpdated', 'uuid')
    }

    apps = @{
        list = @('id', 'name', 'status', 'type')
        detail = @('id', 'name', 'description', 'status', 'type', 'dateCreated', 'lastUpdated', 'uuid')
    }

    activity = @{
        list = @('id', 'name', 'success', 'user', 'message', 'dateCreated')
        detail = @('id', 'name', 'success', 'user', 'message', 'description', 'eventType', 'dateCreated', 'lastUpdated')
    }

    policies = @{
        list = @('id', 'name', 'type', 'scope', 'enabled')
        detail = @('id', 'name', 'type', 'scope', 'enabled', 'description', 'code', 'dateCreated', 'lastUpdated')
    }

    accounts = @{
        list = @('id', 'name', 'role', 'status')
        detail = @('id', 'name', 'username', 'email', 'role', 'status', 'dateCreated', 'lastUpdated')
    }

    users = @{
        list = @('id', 'name', 'username', 'email', 'status')
        detail = @('id', 'name', 'username', 'email', 'role', 'status', 'dateCreated', 'lastUpdated')
    }

    clouds = @{
        list = @('id', 'name', 'type', 'status')
        detail = @('id', 'name', 'type', 'status', 'enabled', 'dateCreated', 'lastUpdated')
    }

    clusters = @{
        list = @('id', 'name', 'type', 'status')
        detail = @('id', 'name', 'type', 'status', 'enabled', 'dateCreated', 'lastUpdated')
    }

    networks = @{
        list = @('id', 'name', 'type', 'cidr', 'vlan', 'active')
        detail = @('id', 'name', 'type', 'cidr', 'vlan', 'active', 'dhcpServer', 'dateCreated', 'lastUpdated')
    }

    plans = @{
        list = @('id', 'name', 'code', 'active')
        detail = @('id', 'name', 'code', 'active', 'description', 'dateCreated', 'lastUpdated')
    }

    tasks = @{
        list = @('id', 'name', 'type', 'status')
        detail = @('id', 'name', 'type', 'status', 'result', 'dateCreated', 'lastUpdated')
    }

    applianceSettings = @{
        list = @('id', 'name', 'code', 'status', 'enabled', 'dateCreated', 'lastUpdated')
        detail = @('id', 'name', 'code', 'status', 'enabled', 'description', 'dateCreated', 'lastUpdated', 'uuid')
    }
}
