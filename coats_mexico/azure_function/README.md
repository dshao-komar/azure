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

The function identity needs:

```text
Microsoft Graph application access to read the watched SharePoint drive items
Azure RBAC permission to call Microsoft.DataFactory/factories/pipelines/createRun/action
```
