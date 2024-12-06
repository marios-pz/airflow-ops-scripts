# Instructions

- Make sure GKE Cluster has CSI driver enabled

```sh
gcloud container clusters update CLUSTER_NAME \
     --update-addons GcsFuseCsiDriver=ENABLED \
     --location=LOCATION
```

Or if you dont have a cluster, create one with CSI driver enabled

```sh
gcloud container clusters create CLUSTER_NAME \
     --addons GcsFuseCsiDriver \
     --cluster-version=VERSION \
     --location=LOCATION \
     --workload-pool=PROJECT_ID.svc.id.goog
```
