# Coats Mexico Graph Notification Function

HTTP route:

```text
graph-sharepoint-notification
```

Required app settings:

```text
ADF_SUBSCRIPTION_ID
ADF_RESOURCE_GROUP
ADF_FACTORY_NAME
ADF_PIPELINE_NAME
GRAPH_DRIVE_ID
GRAPH_NOTIFICATION_URL
GRAPH_SUBSCRIPTION_RESOURCE
SHAREPOINT_WATCH_FOLDER_PATH
```

Recommended watch folder value:

```text
Coats Mexico Shipment Reports
```

The function supports Microsoft Graph subscription validation by echoing the
`validationToken` query parameter. For notifications, it resolves the changed
drive item, ignores non-`.xlsx` and `~$*.xlsx` files, then starts the configured
ADF pipeline with the source file metadata.

## Graph Subscription Renewal

Microsoft Graph subscriptions expire and must be renewed before expiration.
OneDrive `driveItem` subscriptions have a maximum lifetime of 42,300 minutes,
so the Function App includes a daily timer trigger that renews the watched
SharePoint drive subscription to 36,000 minutes, about 25 days, from the renewal
time.

The timer runs daily at 15:00 UTC. It renews active subscriptions matching:

```text
GRAPH_SUBSCRIPTION_RESOURCE
GRAPH_NOTIFICATION_URL
```

If no matching active subscription exists, the job creates a new one. The same
logic can be run manually with:

```text
POST /api/renew-graph-sharepoint-subscription
```

The function identity needs:

```text
Microsoft Graph application access to read the watched SharePoint drive items
Azure RBAC permission to call Microsoft.DataFactory/factories/pipelines/createRun/action
```
