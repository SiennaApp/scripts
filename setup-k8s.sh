#!/bin/bash

set -e

# Function to read from terminal even when piped
read_from_tty() {
    if [ -t 0 ]; then
        # If stdin is a terminal, use normal read
        read "$@"
    else
        # If piped, read from /dev/tty
        read "$@" < /dev/tty
    fi
}

echo "🔧 Sienna Kubernetes Integration Setup"
echo "======================================"
echo

# Get current context
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")

if [ -z "$CURRENT_CONTEXT" ]; then
    echo "❌ No current kubectl context found. Please configure kubectl first."
    exit 1
fi

echo "📍 Current kubectl context: $CURRENT_CONTEXT"
echo

# Ask if they want to use current context or choose a different one
read_from_tty -p "Use this context? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo
    echo "Available contexts:"
    kubectl config get-contexts -o name
    echo
    read_from_tty -p "Enter the context name you want to use: " SELECTED_CONTEXT
    
    if ! kubectl config get-contexts -o name | grep -q "^$SELECTED_CONTEXT$"; then
        echo "❌ Context '$SELECTED_CONTEXT' not found."
        exit 1
    fi
    
    kubectl config use-context "$SELECTED_CONTEXT"
    echo "✅ Switched to context: $SELECTED_CONTEXT"
    CURRENT_CONTEXT="$SELECTED_CONTEXT"
fi

echo
echo "📦 Choose namespace for Sienna service account:"
echo "1. Use 'sienna' namespace (recommended - will be created if it doesn't exist)"
echo "2. Use 'default' namespace"
echo "3. Enter custom namespace"
echo
read_from_tty -p "Select option (1-3) [1]: " -n 1 -r NAMESPACE_CHOICE
echo
echo

# Set default if no input
if [ -z "$NAMESPACE_CHOICE" ]; then
    NAMESPACE_CHOICE="1"
fi

case $NAMESPACE_CHOICE in
    1)
        NAMESPACE="sienna"
        echo "✅ Using 'sienna' namespace"
        ;;
    2)
        NAMESPACE="default"
        echo "✅ Using 'default' namespace"
        ;;
    3)
        echo
        read_from_tty -p "Enter namespace name: " NAMESPACE
        if [ -z "$NAMESPACE" ]; then
            echo "❌ Namespace cannot be empty"
            exit 1
        fi
        echo "✅ Using '$NAMESPACE' namespace"
        ;;
    *)
        echo "❌ Invalid choice. Please run the script again."
        exit 1
        ;;
esac

echo
echo "🚀 Creating Sienna service account in '$NAMESPACE' namespace..."

# Create namespace if it doesn't exist (except for default)
if [ "$NAMESPACE" != "default" ]; then
    echo "📦 Ensuring namespace '$NAMESPACE' exists..."
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Namespace ready"
fi

# Generate the service account manifest dynamically
echo "📝 Generating service account manifest..."
MANIFEST=$(cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sienna-integration-user
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sienna-admin-role
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sienna-admin-binding
subjects:
- kind: ServiceAccount
  name: sienna-integration-user
  namespace: $NAMESPACE
roleRef:
  kind: ClusterRole
  name: sienna-admin-role
  apiGroup: rbac.authorization.k8s.io
EOF
)

# Apply the service account manifest with error handling
if ! echo "$MANIFEST" | kubectl apply -f - 2>/tmp/kubectl_error.log; then
    echo "❌ Failed to create service account. Error details:"
    cat /tmp/kubectl_error.log
    echo
    echo "💡 This usually means you need cluster admin permissions to create ClusterRoles and ClusterRoleBindings."
    echo "   Please ask your Kubernetes administrator to run this command, or ensure you have sufficient permissions."
    echo
    echo "   Required permissions:"
    echo "   - Create ServiceAccounts in the $NAMESPACE namespace"
    echo "   - Create ClusterRoles"
    echo "   - Create ClusterRoleBindings"
    if [ "$NAMESPACE" != "default" ]; then
        echo "   - Create namespaces (if using custom namespace)"
    fi
    rm -f /tmp/kubectl_error.log
    exit 1
fi

echo "✅ Service account created successfully!"
echo

# Wait a moment for the secret to be created
echo "⏳ Waiting for service account token..."
sleep 3

# Get the required values
echo "📋 Extracting configuration values..."
echo

# Use more robust jsonpath queries that work with the current context
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')
API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[?(@.name=="'$CLUSTER_NAME'")].cluster.server}')
CA_DATA=$(kubectl config view --minify -o jsonpath='{.clusters[?(@.name=="'$CLUSTER_NAME'")].cluster.certificate-authority-data}')

if [ -z "$API_SERVER" ]; then
    echo "❌ Could not extract API server URL from kubeconfig"
    exit 1
fi

# For newer Kubernetes versions (1.24+), we need to create a secret manually
SECRET_NAME="sienna-integration-user-token"
echo "🔑 Creating service account token..."

if ! kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: sienna-integration-user
type: kubernetes.io/service-account-token
EOF
then
    echo "❌ Failed to create service account token secret"
    exit 1
fi

# Wait for the token to be populated
echo "⏳ Waiting for token generation..."
sleep 5

# Try to get the token with retries
for i in {1..3}; do
    # Use base64 -d for macOS compatibility, fallback to --decode for Linux
    TOKEN=$(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.token}' 2>/dev/null | (base64 -d 2>/dev/null || base64 --decode 2>/dev/null) || echo "")
    if [ -n "$TOKEN" ]; then
        break
    fi
    echo "⏳ Token not ready yet, waiting... (attempt $i/3)"
    sleep 3
done

if [ -z "$TOKEN" ]; then
    echo "❌ Failed to retrieve service account token. The secret may not be ready yet."
    echo "   You can try running this command manually after a few minutes:"
    echo "   kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.token}' | base64 -d"
    exit 1
fi

echo "✅ Configuration extracted!"
echo
echo "🔑 Copy these values into Sienna:"
echo "====================================="
echo
echo "API Server URL:"
echo "$API_SERVER"
echo
echo "Certificate Authority Data:"
echo "$CA_DATA"
echo
echo "Service Account Token:"
echo "$TOKEN"
echo
echo "✅ Setup complete! You can now configure your Sienna integration." 
