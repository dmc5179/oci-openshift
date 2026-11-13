# Kubernetes LoadBalancer services on OCI

The Oracle cloud controller manager (CCM) provisions an OCI load balancer for each Kubernetes `Service` of `type: LoadBalancer`. This page covers settings that behave differently from what the cluster's CCM configuration suggests. These were found while testing in OC3.

## Network load balancers need their own security-list annotation

The stack's CCM configuration (`cloud-provider.yaml` in the `oci-cloud-controller-manager` secret) sets:

```yaml
loadBalancer:
  securityListManagementMode: Frontend
```

That setting applies only to **classic** load balancers. For a **network** load balancer (`oci.oraclecloud.com/load-balancer-type: "nlb"`), the CCM reads a per-service annotation instead, and its default is `None`. The CCM then adds no ingress rule for the NLB listener. The public subnet's security list admits only the VCN CIDR and TCP 22, so an NLB on the public subnet provisions but doesn't answer clients outside the VCN.

To have the CCM manage the listener rule, set the annotation on the service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: example
  annotations:
    oci.oraclecloud.com/load-balancer-type: "nlb"
    oci-network-load-balancer.oraclecloud.com/security-list-management-mode: "Frontend"
    oci-network-load-balancer.oraclecloud.com/is-preserve-source: "false"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: example
  ports:
  - port: 80
    targetPort: 8080
```

- With `Frontend`, the CCM adds an ingress rule for the listener port to the subnet's security list, and removes it when the service is deleted.
- Use `All` if the CCM should also manage the backend rules.
- The alternative is to add the listener rule to the public security list, or to an NSG, yourself.

## Client source IP preservation

By default an OCI NLB preserves the client's source IP. Backend traffic then arrives at the nodes from the client's address, which the node NSGs and the private security list don't admit, because they allow only the VCN CIDR. To have backend traffic arrive from the NLB instead, set `oci-network-load-balancer.oraclecloud.com/is-preserve-source: "false"`.

The CCM accepts that annotation only with `externalTrafficPolicy: Local`. With `Cluster`, the service never provisions and the CCM reports:

```
oci-network-load-balancer.oraclecloud.com/is-preserve-source annotation cannot be set when externalTrafficPolicy is set to Cluster
```

## Flexible-shape load balancer limits

The cluster itself uses three load balancers: `api`, `api-int` and `*.apps`. If the tenancy's `lb-flexible-count` limit is low (it was 3 in the OC3 test tenancy), services that request a flexible shape stay pending. Check the limit with:

```
oci limits value list --service-name load-balancer --compartment-id <tenancy-ocid> --name lb-flexible-count
```

Either raise the limit, or request a fixed shape with `service.beta.kubernetes.io/oci-load-balancer-shape: "100Mbps"`, or use an NLB.
