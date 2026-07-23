---
title: "Getting Started"
linkTitle: "Getting Started"
weight: 10
---

## Initial Environment
This lab requires you have a working Kubernetes (K8s) environment in Azure. We will be using `helm` via the Azure Cloud Console to setup the existing nodes and pods that we will use during this session.

## Complete Previous Labs First
This lab requires you to have completed the following sections from the "k8s01-101-workshop":

* [Workshop Logistics: Task 1 - Setup Azure Cloud Shell](https://fortinetcloudcse.github.io/k8s-101-workshop/03_participanttasks/03_01_k8sinstall/03_01_02_k8sinstall.html) - This ensures that you have properly setup the Cloud Console and have access that you will need in the next sections.
* [Workshop Logistics: Task 2 - Run Terraform](https://fortinetcloudcse.github.io/k8s-101-workshop/02_quickstart_overview_faq/02_01_quickstart/02_01_03_terraform.html) - This task will ensure that you have a working set of VMs to use as your K8s cluster. This sets up the VMs in Azure via Terraform and ensures that they are ready for the next section.
* [Self Managed K8s Workshop: Task 1 - K8s Installation](https://fortinetcloudcse.github.io/k8s-101-workshop/03_participanttasks/03_01_k8sinstall/03_01_02_k8sinstall.html) - This will install K8s on the VMs for you and make sure that you have all the software required to complete the following sections.

## Confirming the Environment
Let's confirm that the environment is setup correctly and has everything we need before we get started. If any of these checks fail, please go back and confirm that you have completed the sections listed above in "Complete Previous Labs First".

1. Log into [Azure](https://portal.azure.com/) with your student credentials.

1. Access the Azure Cloud Console. The following commands will all be executed from the Cloud Console. 

    ![Azure Cloud Console](<CleanShot 2026-07-23 at 17.22.57.png>)

    If you can't access the Azure Portal or the Azure Cloud Shell please re-run the "Task 1 - Setup Azure Cloud Shell" from the section above.

1. First we will look to see that we have the VMs running in our environment (no VMs, no K8s):

    `az vm list --show-details --query "[?powerState=='VM running'].{Name:name, Status:powerState}" --output table`

    The output should look like:

    ```
    Name         Status
    -----------  ----------
    node-master  VM running
    node-worker  VM running
    ```

    These are our VMs that are going to run K8s, FortiAIGate, and other services for us. If you don't see these VMs running, please re-run the "Task 2 - Run Terraform" section from above.

1. Next, let's check that we can talk to our K8s cluster on those VMs (if we can't talk to k8s then the rest is moot):

    `kubectl get nodes`

    The output should look like:

    ```
    NAME          STATUS   ROLES           AGE     VERSION
    node-master   Ready    control-plane   2d21h   v1.30.14
    node-worker   Ready    <none>          2d20h   v1.30.14
    ```

    If this fails, check the "Task 1 - K8s Installation" section

1. We are going to need `helm` so let's run the following to verify that it is working correctly:

    `helm version`

    The output should look something similar to (build and actual versions may differ depending on updates):

    `version.BuildInfo{Version:"v4.1", GitCommit:"c94d381b03be117e7e57908edbf642104e00eb8f", GitTreeState:"clean", GoVersion:"go1.26.4", KubeClientVersion:"v1.35"}`

1. Make sure we have a CNI (Container Network Interface - how containers talk to each other in K8s) installed:

    `kubectl get pods -A | grep -E "(calico|flannel|weave|cilium)"`

    You should see output that looks something like this:

    ```
    calico-apiserver   calico-apiserver-79c7f68748-fhwnt         1/1     Running   0          3d4h
    calico-apiserver   calico-apiserver-79c7f68748-ndv77         1/1     Running   0          3d4h
    calico-system      calico-kube-controllers-96b9d54b7-5zzt4   1/1     Running   0          3d4h
    calico-system      calico-node-84jf4                         1/1     Running   0          3d4h
    calico-system      calico-node-s5r8m                         1/1     Running   0          3d3h
    calico-system      calico-typha-6979dd87cd-v7gtb             1/1     Running   0          3d4h
    calico-system      csi-node-driver-l2rmb                     2/2     Running   0          3d4h
    calico-system      csi-node-driver-vgcsn                     2/2     Running   0          3d3h
    ```

    We install Calico as part of our K8s deployment in the previous steps, but if you were deploying this on a customer's K8s environment you would want to make sure they have an operational CNI.

### What about Storage
FortiAIGate also requires NFS storage to be setup in K8s. In this environment we are running multiple nodes, but all the pods will run on one container so we don't have to worry about that.

But if you want to test that out and confirm use the following command:

`kubectl get storageclass`

## All Set?
If you have passed all of these checks then you are ready to progress to the next section.