#!/usr/bin/env bash

# This script installs airflow in our gke kubernetes cluster. You can change
# the variable to install the solution on a different cluster (GOOGLE ONLY)

# set -e # Exit immediately if any command fails
# set -o pipefail # Catch errors in pipelines

CLIENT="<CLIENT-NAME>"
PROJECT_ID="<GOOGLE PROJECT ID>"
PROJECT_NUMBER="<GOOGLE PROJECT NUMBER>"
NAMESPACE="<NAMESPACE>"
KUBE_SA_NAME="$CLIENT-airflow-sa"
BUCKET_NAME="$CLIENT-airflow-bucket"
LOCATION="<REGION>"
AIRFLOW_STORAGE_SIZE="5Gi"

# 1. Create Bucket
gcloud storage buckets create gs://$BUCKET_NAME --location="$LOCATION"

# 2. Create Namaspece
kubectl create namespace $NAMESPACE

# 3. Create Google Service Account
gcloud iam service-accounts create "$KUBE_SA_NAME" --project=$PROJECT_ID

# 4. Setup Service Account inside the cluster for that namespace
kubectl create serviceaccount $KUBE_SA_NAME \
    --namespace $NAMESPACE

# 5. Bind Bucket to Kubernetes Service Account
gcloud storage buckets add-iam-policy-binding gs://$BUCKET_NAME \
    --member "principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/$NAMESPACE/sa/$KUBE_SA_NAME" \
    --role "roles/storage.objectUser"

# 6 Bind the the Kubernetes Service Account with the GCP Service Account. The kubernetes resources will be created in the next step.
gcloud iam service-accounts add-iam-policy-binding "$KUBE_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
 --role "roles/iam.workloadIdentityUser" \
 --member "principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/$NAMESPACE/sa/$KUBE_SA_NAME" \
 --project $PROJECT_ID

# 7. Create PersistentVolume
kubectl apply -n $NAMESPACE -f - << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $CLIENT-airflow-pv
spec:
  accessModes:
  - ReadWriteMany
  capacity:
    storage: $AIRFLOW_STORAGE_SIZE
  storageClassName: airflow-storage-class
  mountOptions:
    - implicit-dirs
  csi:
    driver: gcsfuse.csi.storage.gke.io
    volumeHandle: $BUCKET_NAME
    volumeAttributes:
      gcsfuseLoggingSeverity: warning
  claimRef:
    name: $CLIENT-airflow-pvc
    namespace: $NAMESPACE
EOF


# 8. Create PersistentVolumeClaim
kubectl apply -n $NAMESPACE -f - << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $CLIENT-airflow-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: $AIRFLOW_STORAGE_SIZE
  storageClassName: airflow-storage-class
EOF

FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
WEB_SERVER_SECRET_KEY=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)

# 9. Install airflow
helm install \
  airflow \
  airflow-stable/airflow \
  --namespace $NAMESPACE \
  --values ./airflow-community-values.yaml \
  --set airflow.image.repository="apache/airflow" \
  --set airflow.image.tag="2.8.4-python3.9" \
  --set fernetKey="$FERNET_KEY" \
  --set webserverSecretKey="$WEB_SERVER_SECRET_KEY" \
  --set airflow.users[0].email="$ADMIN_EMAIL" \
  --set airflow.users[0].password="$ADMIN_PASSWORD" \
  --set dags.persistence.existingClaim="$CLIENT-airflow-pvc" \
  --set extraVolumes[0].persistentVolumeClaim.claimName="$CLIENT-airflow-pvc" \
  --set serviceAccount.name="$KUBE_SA_NAME" \
  --set serviceAccount.annotations."iam.gserviceaccount.com"="$KUBE_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
