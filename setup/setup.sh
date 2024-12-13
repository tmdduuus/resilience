#!/bin/bash

# ===========================================
# 신뢰성 패턴 실습환경 구성 스크립트
# ===========================================

# 사용법 출력
print_usage() {
    cat << EOF
사용법:
    $0 <userid>

설명:
    신뢰성 패턴 실습을 위한 Azure 리소스를 생성합니다.
    리소스 이름이 중복되지 않도록 userid를 prefix로 사용합니다.

예제:
    $0 gappa     # gappa-resilience 등의 리소스가 생성됨
EOF
}

# 유틸리티 함수
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a $LOG_FILE
}

check_error() {
    local status=$?
    if [ $status -ne 0 ]; then
        log "Error: $1 (Exit Code: $status)"
        exit $status
    fi
}

# Azure CLI 로그인 체크
check_azure_cli() {
    log "Azure CLI 로그인 상태 확인 중..."
    if ! az account show &> /dev/null; then
        log "Azure CLI 로그인이 필요합니다."
        az login --use-device-code
        check_error "Azure 로그인 실패"
    fi
}

# 환경 변수 설정
setup_environment() {
    USERID=$1
    NAME="${USERID}-resilience"
    NAMESPACE="${NAME}-ns"
    RESOURCE_GROUP="tiu-dgga-rg"
    LOCATION="koreacentral"
    AKS_NAME="${USERID}-aks"
    ACR_NAME="${USERID}cr"
    VNET_NAME="tiu-dgga-vnet"
    SUBNET_AKS="tiu-dgga-aks-snet"

    # MongoDB 설정
    MONGODB_HOST="${NAME}-mongodb"
    MONGODB_PORT="27017"
    MONGODB_DATABASE="membershipdb"
    MONGODB_USER="root"
    MONGODB_PASSWORD="Passw0rd"

    # PostgreSQL 설정
    POSTGRES_HOST="${NAME}-postgres"
    POSTGRES_PORT="5432"
    POSTGRES_DB="membershipdb"
    POSTGRES_USER="postgres"
    POSTGRES_PASSWORD="postgres"

    # Secret 이름
    MONGO_SECRET_NAME="${USERID}-mongo-secret"
    POSTGRES_SECRET_NAME="${USERID}-postgres-secret"

    # Event Grid 설정
    GATEWAY_TOPIC="$NAME-gateway-topic"
    ASYNC_TOPIC="$NAME-async-topic"

    # Gateway Event Grid 환경변수
    GATEWAY_EVENTGRID_ENDPOINT=""
    GATEWAY_EVENTGRID_KEY=""

    # Async Event Grid 환경변수
    ASYNC_EVENTGRID_ENDPOINT=""
    ASYNC_EVENTGRID_KEY=""

   # Event Grid
   STORAGE_ACCOUNT="${USERID}storage"
   DEAD_LETTER="${USERID}deadletter"

    # Event Grid IPs
    PROXY_IP="4.217.249.140"
    ASYNC_PUBIP="20.214.193.100"
    SUB_ENDPOINT=""

    LOG_FILE="deployment_${NAME}.log"

    log "환경 변수 설정 완료"
}

# ACR 권한 설정
setup_acr_permission() {
    log "ACR pull 권한 확인 중..."

    # AKS의 Managed Identity 확인
    SP_ID=$(az aks show \
        --name $AKS_NAME \
        --resource-group $RESOURCE_GROUP \
        --query identityProfile.kubeletidentity.clientId -o tsv)
    check_error "AKS Managed Identity 조회 실패"

    # ACR ID 가져오기
    ACR_ID=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query "id" -o tsv)
    check_error "ACR ID 조회 실패"

    # Role assignment 확인 및 할당
    ROLE_EXISTS=$(az role assignment list --assignee $SP_ID --scope $ACR_ID --query "[?roleDefinitionName=='AcrPull']" -o tsv)
    if [ -z "$ROLE_EXISTS" ]; then
        az role assignment create \
            --assignee $SP_ID \
            --scope $ACR_ID \
            --role AcrPull
        check_error "ACR pull 권한 부여 실패"
    fi
}

# k8s object 삭제
clear_resources() {
    # 기존 리소스 삭제
    kubectl delete deploy --all -n $NAMESPACE 2>/dev/null || true
    kubectl delete sts --all -n $NAMESPACE 2>/dev/null || true
    kubectl delete pvc --all -n $NAMESPACE 2>/dev/null || true
    kubectl delete cm --all -n $NAMESPACE 2>/dev/null || true
    kubectl delete secret --all -n $NAMESPACE 2>/dev/null || true
}

# 공통 리소스 설정
setup_common_resources() {
    log "공통 리소스 설정 중..."

    # 네임스페이스 생성
    kubectl create namespace $NAMESPACE 2>/dev/null || true

    # Gateway Event Grid Topic 체크 및 생성
    local topic_exists=$(az eventgrid topic show \
        --name $GATEWAY_TOPIC \
        --resource-group $RESOURCE_GROUP \
        --query "provisioningState" -o tsv 2>/dev/null)

    if [ "$topic_exists" != "Succeeded" ]; then
        log "Gateway Event Grid Topic 생성 중..."
        az eventgrid topic create \
            --name $GATEWAY_TOPIC \
            --resource-group $RESOURCE_GROUP \
            --location $LOCATION \
            --output none
        check_error "Gateway Event Grid Topic 생성 실패"
    else
        log "Gateway Event Grid Topic이 이미 존재합니다"
    fi

    # Gateway Event Grid 환경변수 설정
    GATEWAY_EVENTGRID_ENDPOINT=$(az eventgrid topic show --name $GATEWAY_TOPIC -g $RESOURCE_GROUP --query "endpoint" -o tsv)
    GATEWAY_EVENTGRID_KEY=$(az eventgrid topic key list --name $GATEWAY_TOPIC -g $RESOURCE_GROUP --query "key1" -o tsv)

    # Async Event Grid Topic 체크 및 생성
    topic_exists=$(az eventgrid topic show \
        --name $ASYNC_TOPIC \
        --resource-group $RESOURCE_GROUP \
        --query "provisioningState" -o tsv 2>/dev/null)

    if [ "$topic_exists" != "Succeeded" ]; then
        log "Async Event Grid Topic 생성 중..."
        az eventgrid topic create \
            --name $ASYNC_TOPIC \
            --resource-group $RESOURCE_GROUP \
            --location $LOCATION \
            --output none
        check_error "Async Event Grid Topic 생성 실패"
    else
        log "Async Event Grid Topic이 이미 존재합니다"
    fi

    # Async Event Grid 환경변수 설정
    ASYNC_EVENTGRID_ENDPOINT=$(az eventgrid topic show --name $ASYNC_TOPIC -g $RESOURCE_GROUP --query "endpoint" -o tsv)
    ASYNC_EVENTGRID_KEY=$(az eventgrid topic key list --name $ASYNC_TOPIC -g $RESOURCE_GROUP --query "key1" -o tsv)

    # Storage Account가 없으면 생성
    STORAGE_EXISTS=$(az storage account show \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query name \
        --output tsv 2>/dev/null)

    if [ -z "$STORAGE_EXISTS" ]; then
        az storage account create \
            --name $STORAGE_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --location $LOCATION \
            --sku Standard_LRS
        check_error "Storage Account 생성 실패"
    fi

    # Storage Account connection string 가져오기
    local storage_conn_str=$(az storage account show-connection-string \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query connectionString \
        --output tsv)
    check_error "Storage connection string 조회 실패"

    # deadletter 컨테이너 존재 여부 확인
    local container_exists=$(az storage container exists \
        --name $DEAD_LETTER \
        --connection-string "$storage_conn_str" \
        --query "exists" -o tsv)

    if [ "$container_exists" != "true" ]; then
        # deadletter 컨테이너 생성
        az storage container create \
            --name $DEAD_LETTER \
            --connection-string "$storage_conn_str" \
            --output none
        check_error "Storage container 생성 실패"
    else
        log "Deadletter 컨테이너가 이미 존재합니다"
    fi
}

# Database Secret 생성
setup_database_secrets() {
    log "Database Secret 생성 중..."

    # MongoDB Secret 생성
    kubectl create secret generic $MONGO_SECRET_NAME \
        --namespace $NAMESPACE \
        --from-literal=mongodb-root-password=$MONGODB_PASSWORD \
        --from-literal=mongodb-password=$MONGODB_PASSWORD \
        2>/dev/null || true

    # PostgreSQL Secret 생성
    kubectl create secret generic $POSTGRES_SECRET_NAME \
        --namespace $NAMESPACE \
        --from-literal=postgresql-password=$POSTGRES_PASSWORD \
        2>/dev/null || true
}

# MongoDB 설정
setup_mongodb() {
    log "MongoDB 설정 중..."

    # MongoDB 초기화 스크립트 ConfigMap 생성
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongo-init
  namespace: $NAMESPACE
data:
  mongo-init.js: |
    db = db.getSiblingDB('$MONGODB_DATABASE');
    db.createUser({
      user: '$MONGODB_USER',
      pwd: '$MONGODB_PASSWORD',
      roles: [{ role: 'readWrite', db: '$MONGODB_DATABASE' }]
    });
EOF

    # MongoDB StatefulSet 생성
    cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $MONGODB_HOST
  namespace: $NAMESPACE
spec:
  serviceName: $MONGODB_HOST
  replicas: 1
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
      - name: mongodb
        image: mongo:4.4
        env:
        - name: MONGO_INITDB_ROOT_USERNAME
          value: $MONGODB_USER
        - name: MONGO_INITDB_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: $MONGO_SECRET_NAME
              key: mongodb-root-password
        - name: MONGO_INITDB_DATABASE
          value: $MONGODB_DATABASE
        ports:
        - containerPort: 27017
        volumeMounts:
        - name: mongodb-data
          mountPath: /data/db
        - name: mongo-init
          mountPath: /docker-entrypoint-initdb.d
      volumes:
      - name: mongo-init
        configMap:
          name: mongo-init
  volumeClaimTemplates:
  - metadata:
      name: mongodb-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: $MONGODB_HOST
  namespace: $NAMESPACE
spec:
  selector:
    app: mongodb
  ports:
  - port: 27017
    targetPort: 27017
  type: ClusterIP
EOF
}

# PostgreSQL 설정
setup_postgresql() {
    log "PostgreSQL 설정 중..."

    cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $POSTGRES_HOST
  namespace: $NAMESPACE
spec:
  serviceName: $POSTGRES_HOST
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
      - name: postgresql
        image: postgres:13
        env:
        - name: POSTGRES_USER
          value: $POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: $POSTGRES_SECRET_NAME
              key: postgresql-password
        - name: POSTGRES_DB
          value: $POSTGRES_DB
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/postgresql/data
          subPath: postgres
  volumeClaimTemplates:
  - metadata:
      name: postgresql-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: $POSTGRES_HOST
  namespace: $NAMESPACE
spec:
  selector:
    app: postgresql
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF
}

# 서비스 빌드 및 배포
deploy_service() {
    local service_name=$1
    local port=$2
    local fixed_ip=$3
    log "${service_name} 서비스 배포 시작..."

    # JAR 빌드 (멀티프로젝트 빌드)
    ./gradlew ${service_name}:clean ${service_name}:build -x test
    check_error "${service_name} jar 빌드 실패"

    # Dockerfile 생성
    cat > "${service_name}/Dockerfile" << EOF
FROM eclipse-temurin:17-jdk-alpine
COPY build/libs/${service_name}.jar app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
EOF

    # 이미지 빌드
    cd "${service_name}"
    az acr build \
        --registry $ACR_NAME \
        --image "membership/${service_name}:v1" \
        --file Dockerfile \
        .
    cd ..
    check_error "${service_name} 이미지 빌드 실패"

    # ConfigMap 생성
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${service_name}-config
  namespace: $NAMESPACE
data:
  APP_NAME: "${service_name}-service"
  SERVER_PORT: "$port"
  MONGODB_HOST: "$MONGODB_HOST"
  MONGODB_PORT: "$MONGODB_PORT"
  MONGODB_DATABASE: "$MONGODB_DATABASE"
  MONGODB_USER: "$MONGODB_USER"
  POSTGRES_HOST: "$POSTGRES_HOST"
  POSTGRES_PORT: "$POSTGRES_PORT"
  POSTGRES_DB: "$POSTGRES_DB"
  POSTGRES_USER: "$POSTGRES_USER"
EOF

    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: resilience-config
  namespace: ${NAMESPACE}
data:
  # Bulkhead 설정
  BULKHEAD_DEFAULT_MAX_CONCURRENT_CALLS: "50"       # 기본 최대 동시 요청 수
  BULKHEAD_DEFAULT_MAX_WAIT_DURATION: "500"         # 기본 최대 대기 시간(ms)

  BULKHEAD_MART_MAX_CONCURRENT_CALLS: "100"         # MART 최대 동시 요청 수
  BULKHEAD_MART_MAX_WAIT_DURATION: "500"            # MART 최대 대기 시간(ms)

  BULKHEAD_CONVENIENCE_MAX_CONCURRENT_CALLS: "200"   # CONVENIENCE 최대 동시 요청 수
  BULKHEAD_CONVENIENCE_MAX_WAIT_DURATION: "300"      # CONVENIENCE 최대 대기 시간(ms)

  BULKHEAD_ONLINE_MAX_CONCURRENT_CALLS: "50"        # ONLINE 최대 동시 요청 수
  BULKHEAD_ONLINE_MAX_WAIT_DURATION: "1000"         # ONLINE 최대 대기 시간(ms)

  # Retry 설정
  RETRY_COUNT: "3"
  RETRY_STATUSES: "BAD_GATEWAY,SERVICE_UNAVAILABLE"
  RETRY_METHODS: "GET,POST"
  RETRY_FIRST_BACKOFF: "5000"
  RETRY_MAX_BACKOFF: "20000"
  RETRY_FACTOR: "2"
  RETRY_BASED_ON_PREVIOUS: "false"

  # Rate Limiter - MART
  RATE_MART_LIMIT: "100"
  RATE_MART_REFRESH: "1"
  RATE_MART_TIMEOUT: "5"

  # Rate Limiter - CONVENIENCE
  RATE_CONVENIENCE_LIMIT: "200"
  RATE_CONVENIENCE_REFRESH: "1"
  RATE_CONVENIENCE_TIMEOUT: "2"

  # Rate Limiter - ONLINE
  RATE_ONLINE_LIMIT: "50"
  RATE_ONLINE_REFRESH: "1"
  RATE_ONLINE_TIMEOUT: "10"

  # Circuit Breaker
  CB_SLIDING_WINDOW_SIZE: "10"
  CB_FAILURE_RATE_THRESHOLD: "50"
  CB_WAIT_DURATION_IN_OPEN: "30000"
  CB_PERMITTED_CALLS_IN_HALF_OPEN: "5"
EOF

    # Gateway configmap 생성

    # Event Grid Secret 생성
    if [ "$service_name" = "gateway" ]; then
        cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${service_name}-eventgrid-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
  EVENTGRID_ENDPOINT: "$GATEWAY_EVENTGRID_ENDPOINT"
  EVENTGRID_KEY: "$GATEWAY_EVENTGRID_KEY"
  EVENTGRID_DLQ_TOPIC: "$GATEWAY_TOPIC"
EOF

    elif [ "$service_name" = "async" ]; then
        cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${service_name}-eventgrid-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
  EVENTGRID_ENDPOINT: "$ASYNC_EVENTGRID_ENDPOINT"
  EVENTGRID_KEY: "$ASYNC_EVENTGRID_KEY"
  EVENTGRID_DLQ_TOPIC: "$ASYNC_TOPIC"
EOF
    fi

    # Deployment YAML 생성
    local loadbalancer_ip=""
    if [ ! -z "$fixed_ip" ]; then
        loadbalancer_ip="loadBalancerIP: $fixed_ip"
    fi

    # Deployment YAML 생성
    cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${service_name}-deploy
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $service_name
  template:
    metadata:
      labels:
        app: $service_name
    spec:
      containers:
      - name: $service_name
        image: ${ACR_NAME}.azurecr.io/membership/${service_name}:v1
        imagePullPolicy: Always
        ports:
        - containerPort: $port
        env:
        - name: APP_NAME
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: APP_NAME
        - name: SERVER_PORT
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: SERVER_PORT
        - name: MONGODB_HOST
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: MONGODB_HOST
        - name: MONGODB_PORT
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: MONGODB_PORT
        - name: MONGODB_DATABASE
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: MONGODB_DATABASE
        - name: MONGODB_USER
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: MONGODB_USER
        - name: MONGODB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: $MONGO_SECRET_NAME
              key: mongodb-password
        - name: POSTGRES_HOST
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: POSTGRES_PORT
        - name: POSTGRES_DB
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: POSTGRES_DB
        - name: POSTGRES_USER
          valueFrom:
            configMapKeyRef:
              name: ${service_name}-config
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: $POSTGRES_SECRET_NAME
              key: postgresql-password
EOF

    # Event Grid 환경변수가 있는 경우 추가 ConfigMap 생성
    if [ "$service_name" = "gateway" ] || [ "$service_name" = "async" ]; then
        kubectl patch deployment ${service_name}-deploy -n $NAMESPACE --type=json -p='[
          {
            "op": "add",
            "path": "/spec/template/spec/containers/0/envFrom",
            "value": [
              {
                "configMapRef": {
                  "name": "resilience-config"
                }
              }
            ]
          },
          {
            "op": "add",
            "path": "/spec/template/spec/containers/0/env/-",
            "value": {
              "name": "EVENTGRID_ENDPOINT",
              "valueFrom": {
                "secretKeyRef": {
                  "name": "'${service_name}'-eventgrid-secret",
                  "key": "EVENTGRID_ENDPOINT"
                }
              }
            }
          },
          {
            "op": "add",
            "path": "/spec/template/spec/containers/0/env/-",
            "value": {
              "name": "EVENTGRID_KEY",
              "valueFrom": {
                "secretKeyRef": {
                  "name": "'${service_name}'-eventgrid-secret",
                  "key": "EVENTGRID_KEY"
                }
              }
            }
          },
          {
            "op": "add",
            "path": "/spec/template/spec/containers/0/env/-",
            "value": {
              "name": "EVENTGRID_DLQ_TOPIC",
              "valueFrom": {
                "secretKeyRef": {
                  "name": "'${service_name}'-eventgrid-secret",
                  "key": "EVENTGRID_DLQ_TOPIC"
                }
              }
            }
          }
        ]'
    fi

# 서비스 생성
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${service_name}-svc
  namespace: $NAMESPACE
spec:
  selector:
    app: $service_name
  ports:
  - protocol: TCP
    port: 80
    targetPort: $port
  type: LoadBalancer
  $loadbalancer_ip
EOF

    # Deployment Ready 대기
    kubectl rollout status deployment/${service_name}-deploy -n $NAMESPACE
    check_error "${service_name} Deployment 준비 실패"
}

# Event Grid Subscriber 설정
setup_event_grid_subscriber() {
    log "Event Grid Subscriber 설정 중..."

    # Storage Account ID 가져오기
    local storage_id=$(az storage account show \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query id \
        --output tsv)
    check_error "Storage Account ID 조회 실패"

    # Async service endpoint - webhook으로 변경
    SUB_ENDPOINT="https://${USERID}.${PROXY_IP}.nip.io/api/events/point"

    # Topic들을 하나의 subscription으로 통합
    subscription_exists=$(az eventgrid event-subscription show \
        --name "${NAME}-sub" \
        --source-resource-id $(az eventgrid topic show --name $GATEWAY_TOPIC -g $RESOURCE_GROUP --query "id" -o tsv) \
        --query "provisioningState" -o tsv 2>/dev/null)

    if [ "$subscription_exists" = "Succeeded" ]; then
        log "Event Grid Subscription이 이미 존재합니다"
    else
        log "Event Grid Subscription 생성 중..."

        # Gateway Topic Subscription 생성
        az eventgrid event-subscription create \
            --name "${NAME}-sub" \
            --source-resource-id $(az eventgrid topic show --name $GATEWAY_TOPIC -g $RESOURCE_GROUP --query "id" -o tsv) \
            --endpoint $SUB_ENDPOINT \
            --endpoint-type webhook \
            --included-event-types CircuitBreakerOpened RetryExhausted ProcessingFailed \
            --max-delivery-attempts 3 \
            --event-ttl 1440 \
            --deadletter-endpoint "${storage_id}/blobServices/default/containers/$DEAD_LETTER" \
            --output none
        check_error "Event Grid Subscriber 생성 실패"
    fi
}

# 결과 출력
print_results() {
    log "=== 배포 결과 ==="
    kubectl get all -n $NAMESPACE

    log "=== 서비스 URL ==="
    for svc in async gateway point; do
        local ip=$(kubectl get svc ${svc}-svc -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        log "${svc} Service URL: http://${ip}"
    done

    log "=== Event Grid 정보 ==="
    log "Gateway Topic: $GATEWAY_TOPIC"
    log "Async Topic: $ASYNC_TOPIC"
    log "Event Grid Subscription Endpoint: ${SUB_ENDPOINT}"
}

# 메인 실행 함수
main() {
    if [ $# -ne 1 ]; then
        print_usage
        exit 1
    fi

    if [[ ! $1 =~ ^[a-z0-9]+$ ]]; then
        echo "Error: userid는 영문 소문자와 숫자만 사용할 수 있습니다."
        exit 1
    fi

    # 환경 설정
    setup_environment "$1"

    # 사전 체크
    check_azure_cli

    # ACR 권한 설정
    setup_acr_permission

    # 기존 k8s 리소스 삭제
    clear_resources

    # 공통 리소스 설정
    setup_common_resources

    # Database Secret 설정
    setup_database_secrets

    # Database 설정
    setup_mongodb
    setup_postgresql

    # 데이터베이스 준비 상태 대기
    log "데이터베이스 준비 상태 대기 중..."
    kubectl wait --for=condition=ready pod -l app=mongodb -n $NAMESPACE --timeout=300s
    kubectl wait --for=condition=ready pod -l app=postgresql -n $NAMESPACE --timeout=300s
    log "데이터베이스 준비 완료"

    # 서비스 배포
    deploy_service "async" "8082" "$ASYNC_PUBIP"
    deploy_service "gateway" "8080" ""
    deploy_service "point" "8081" ""

    # Event Grid Subscriber 설정
    setup_event_grid_subscriber

    # 결과 출력
    print_results

    log "모든 리소스가 성공적으로 생성되었습니다."
}

# 스크립트 시작
main "$@"