#!/bin/bash

[ -z $4 ] && echo "Usage: $0 <namespace> <OpenVPN URL> <service cidr> <pod cidr>" && exit 1

namespace=$1
serverurl=$2
servicecidr=$3
podcidr=$4

# Server name is in the form "udp://vpn.example.com:1194"
if [[ "$serverurl" =~ ^((udp|tcp)://)?([0-9a-zA-Z\.\-]+)(:([0-9]+))?$ ]]; then
    OVPN_PROTO=$(echo ${BASH_REMATCH[2]} | tr '[:lower:]' '[:upper:]')
    OVPN_CN=$(echo ${BASH_REMATCH[3]} | tr '[:upper:]' '[:lower:]')
    OVPN_PORT=${BASH_REMATCH[5]};
else
    echo "Need to pass in OpenVPN URL in 'proto://fqdn:port' format"
    echo "eg: tcp://my.fully.qualified.domain.com:1194"
    exit 1
fi
OVPN_PORT="${OVPN_PORT:-1194}"

if [ ! -d pki ]; then
    echo "This script requires a directory named 'pki' in the current working directory, populated with a CA generated by easyrsa"
    echo "You can easily generate this. Execute the following command and follow the instructions on screen:"
    echo "docker run -e OVPN_SERVER_URL=$serverurl -v $PWD:/etc/openvpn -ti ptlange/openvpn ovpn_initpki"
    exit 1
fi

if [ $(uname -s) == "Linux" ]; then
    base64="base64 -w0"
else
    base64="base64"
fi

kubectl create --namespace=$namespace -f - <<- EOSECRETS
apiVersion: v1
kind: Secret
metadata:
  name: openvpn-pki
type: Opaque
data:
  private.key: "$($base64 pki/private/${OVPN_CN}.key)"
  ca.crt: "$($base64 pki/ca.crt)"
  certificate.crt: "$($base64 pki/issued/${OVPN_CN}.crt)"
  dh.pem: "$($base64 pki/dh.pem)"
  ta.key: "$($base64 pki/ta.key)"
---
EOSECRETS

kubectl create --namespace=$namespace -f - <<- EOCONFIGMAP
apiVersion: v1
kind: ConfigMap
metadata:
  name: openvpn-settings
data:
  servicecidr: "${servicecidr}"
  podcidr: "${podcidr}"
  serverurl: "${serverurl}"
  portforwards: "080 443"
---
EOCONFIGMAP

kubectl create --namespace=$namespace -f - <<- EOCONFIGMAP
apiVersion: v1
kind: ConfigMap
metadata:
  name: openvpn-ccd
data:
  example: "ifconfig-push 10.140.0.5 255.255.255.0"
---
EOCONFIGMAP

kubectl create --namespace=$namespace -f - <<- EODEPLOYMENT
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: openvpn
spec:
  revisionHistoryLimit: 1
  replicas: 1
  template:
    metadata:
      labels:
        openvpn: ${OVPN_CN}
    spec:
      restartPolicy: Always
      terminationGracePeriodSeconds: 60
      containers:
      - name: openvpn
        image: ptlange/openvpn:latest
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
        resources:
          limits:
            cpu: 200m
            memory: 100Mi
          requests:
            cpu: 100m
            memory: 50Mi
        volumeMounts:
        - mountPath: /etc/openvpn/pki
          name: openvpn-pki
        - mountPath: /etc/openvpn/ccd
          name: openvpn-ccd
        env:
        - name: PODIPADDR
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: PORTFORWARDS
          valueFrom:
            configMapKeyRef:
              name: openvpn-settings
              key: portforwards
        - name: OVPN_SERVER_URL
          valueFrom:
            configMapKeyRef:
              name: openvpn-settings
              key: serverurl
        - name: OVPN_K8S_SERVICE_NETWORK
          valueFrom:
            configMapKeyRef:
              name: openvpn-settings
              key: servicecidr
        - name: OVPN_K8S_POD_NETWORK
          valueFrom:
            configMapKeyRef:
              name: openvpn-settings
              key: podcidr
      volumes:
      - name: openvpn-pki
        secret:
          secretName: openvpn-pki
      - name: openvpn-ccd
        configMap:
          name: openvpn-ccd
---
EODEPLOYMENT


kubectl create --namespace=$namespace -f - <<- EOSERVICE
---
apiVersion: v1
kind: Service
metadata:
  labels:
    openvpn: ${OVPN_CN}
  name: openvpn-ingress
spec:
  type: NodePort
  ports:
  - port: 1194
    protocol: ${OVPN_PROTO}
    targetPort: $OVPN_PORT
  selector:
    openvpn: ${OVPN_CN}
---
EOSERVICE
