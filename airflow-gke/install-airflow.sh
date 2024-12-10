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
AIRFLOW_IMAGE_REPO="apache/airflow"
AIRFLOW_IMAGE_TAG="2.8.4-python3.9"
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

ADMIN_PASSWORD=$(echo -n "$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)" | base64)



# 9. Generate admin and airflow secrets
if kubectl get secret airflow-secrets -n "$NAMESPACE" > /dev/null 2>&1; then
  echo "Secret 'airflow-secrets' already exists in namespace '$NAMESPACE'."
  EXISTING_PASSWORD=$(kubectl get secret airflow-secrets -n "$NAMESPACE" -o jsonpath="{.data.AIRFLOW_ADMIN_PASSWORD}" | base64 --decode)

  if [ -n "$EXISTING_PASSWORD" ]; then
    echo "ADMIN_PASSWORD already exists: $EXISTING_PASSWORD"
  else
    echo "ADMIN_PASSWORD is empty. Generating a new one."
    ADMIN_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16 | base64)
    kubectl patch secret airflow-secrets -n "$NAMESPACE" --type='json' -p="[{\"op\": \"replace\", \"path\": \"/data/AIRFLOW_ADMIN_PASSWORD\", \"value\": \"$ADMIN_PASSWORD\"}]"
    echo "Updated Secret with new ADMIN_PASSWORD."
  fi
else
  echo "Secret 'airflow-secrets' does not exist. Creating a new one."
  ADMIN_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16 | base64)
  kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: airflow-secrets
  namespace: $NAMESPACE
type: Opaque
data:
  AIRFLOW_ADMIN_PASSWORD: "$ADMIN_PASSWORD"
EOF

  echo "Secret 'airflow-secrets' created with ADMIN_PASSWORD."
fi


# 10. Install airflow
helm install \
  airflow \
  airflow-stable/airflow \
  --namespace $NAMESPACE \
  --values ./airflow-community-values.yaml \
  --set airflow.image.repository="$AIRFLOW_IMAGE_REPO" \
  --set airflow.image.tag="$AIRFLOW_IMAGE_TAG" \
  --set airflow.fernetKey="$FERNET_KEY" \
  --set airflow.webserverSecretKey="$WEB_SERVER_SECRET_KEY" \
  --set airflow.users[0].email="$ADMIN_EMAIL" \
  --set dags.persistence.existingClaim="$CLIENT-airflow-pvc" \
  --set extraVolumes[0].persistentVolumeClaim.claimName="$CLIENT-airflow-pvc" \
  --set serviceAccount.name="$KUBE_SA_NAME" \
  --set serviceAccount.annotations."iam.gserviceaccount.com"="$KUBE_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
