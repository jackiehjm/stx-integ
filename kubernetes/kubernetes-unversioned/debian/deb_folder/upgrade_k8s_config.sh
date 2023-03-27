#!/bin/bash
# Copyright (c) 2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

# This will run during k8s upgrades as a part of the control-plane upgrade of
# the first master. It updates the kubeadm-config configmap to edit the
# manifests and updates feature-gates as required for the specific k8s version
# it is upgrading to.
#
# The script updates feature gates for versions 1.22 and 1.24.
# 
# It removes below feature gates from kube-apiserver configmap while upgrading
# k8s 1.21.8 to 1.22.5: SCTPSupport=true, HugePageStorageMediumSize=true
# and TTLAfterFinished=true and removes RemoveSelfLink=false while upgrading
# 1.23.1 to 1.24.4.
#
# Background:
# HugePageStorageMediumSize is deprecated in Kubernetes 1.22
# SCTPSupport blocks kube-apiserver pod to spawn after control-plane upgrade.
# TTLAfterFinished value defaults to true from k8s 1.21
# Kubernetes 1.24 no longer allows setting kube-apsierver feature-gate
# RemoveSelfLink=false. All the other feature gates we were using now default
# to true so we don't want to specify them anymore.

# Temporary configuration file
KUBEADM_CONFIGMAP_TMPFILE=$(mktemp /tmp/kubeadm_cm.yaml.XXXXXX 2>/dev/null)

# Log info message to /var/log/daemon.log
function LOG {
    logger -p daemon.info "$0($$): " "${@}"
}

# Log error message to /var/log/daemon.log
function ERROR {
    logger -s -p daemon.error "$0($$): " "${@}"
}

# Cleanup and exit
function cleanup_and_exit {
    rm -v -f "${KUBEADM_CONFIGMAP_TMPFILE}" 2>/dev/null
    exit "${1:-0}"
}

function get_kubeadm_configmap {
    LOG "Retrieving kubeadm configmap: ${KUBEADM_CONFIGMAP_TMPFILE}"
    local counter=0
    local RETRIES=10
    RC=0
    until  [ ${counter} -gt ${RETRIES} ]; do
        kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system get \
            configmap kubeadm-config -o yaml > "${KUBEADM_CONFIGMAP_TMPFILE}"
        RC=$?
        if [ "${RC}" == "0" ] ; then
            LOG "Kubeadm configmap retrieved."
            break
        fi
        ERROR "Error retrieving kubeadm configmap, retrying..."
        sleep 5
        counter=$(( counter+1 ))
    done

    if [ ${counter} -gt ${RETRIES} ]; then
        ERROR "Failed to retrieve kubeadm configmap with error code [${RC}]".
        cleanup_and_exit ${RC}
    fi
}

# Remove the "RemoveSelfLink=false" kube-apiserver feature gate from the service parameters.
# This is needed to ensure that a backup taken after the upgrade to K8s 1.24 will be
# properly restored without this feature gate.  (K8s 1.24 no longer supports this feature gate.)
function update_feature_gates_service_param_v1_24 {

    # Enable authentication.
    source /etc/platform/openrc

    # Check if any kube-apiserver feature gates are specified in the service parameters.
    TMP=`system service-parameter-list|grep kube_apiserver|grep feature-gates`
    if [ $? -ne 0 ]; then
        # no feature-gates specified, nothing to do
        LOG "No kube-apiserver feature-gates service param specified, nothing to do."
        return
    fi

    # Get the actual feature gates.
    # The xargs call here strips any whitespace.
    FEATURE_GATES=`echo ${TMP}|cut -d'|' -f6|xargs`
    if [ -z "${FEATURE_GATES}" ]; then
        # No feature-gates, nothing to do.  Really shouldn't hit this, just being paranoid.
        LOG "No kube-apiserver feature-gates specified, nothing to do."
        return
    fi

    # Check if the specific feature gate we care about is specified.
    echo ${FEATURE_GATES}|grep -q "RemoveSelfLink=false"
    if [ $? -ne 0 ]; then
        # RemoveSelfLink=false is not specified, nothing to do
        LOG "RemoveSelfLink=false kube-apiserver feature gate not specified, nothing to do."
        return
    fi

    # Remove "RemoveSelfLink=false" from the feature gates.
    # We need to handle the case where it could be at the beginning of the string
    # with other entries after it, or at the end of the string with other entries
    # before it, in the middle of the string, or by itself.
    NEW_FEATURE_GATES=${FEATURE_GATES//'RemoveSelfLink=false,'/}
    NEW_FEATURE_GATES=${NEW_FEATURE_GATES//',RemoveSelfLink=false'/}
    NEW_FEATURE_GATES=${NEW_FEATURE_GATES//'RemoveSelfLink=false'/}

    if [ -z "${NEW_FEATURE_GATES}" ]; then
        # no other feature gates, so delete the service parameter rather than modify it
        UUID=`echo ${TMP}|cut -d'|' -f2`
        system service-parameter-delete ${UUID}
        if [ $? -eq 0 ]; then
            LOG "Successfully deleted RemoveSelfLink=false feature gate service parameter ${UUID}"
        else
            LOG "Failed to delete RemoveSelfLink=false feature gate service parameter ${UUID}"
        fi
    else
        # need to modify the service parameter with the new feature gates
        system service-parameter-modify kubernetes kube_apiserver feature-gates=${NEW_FEATURE_GATES}
        if [ $? -eq 0 ]; then
            LOG "Successfully modified kube-apiserver feature gate service parameter."
        else
            LOG "Failed to modify kube-apiserver feature gate service parameter."
        fi
    fi
}

# This needs to edit a yaml file, so we call out to a python helper.
function update_kube_extra_config_bootstrap_v1_24 {
    /usr/local/sbin/sanitize_feature_gates.py
    if [ $? -ne 0 ]; then
        LOG "Problem running sanitize_feature_gates.py, may cause problems with backup/restore."
    fi
}

# Update feature gates for version 1.22
function update_feature_gates_v1_22 {
    LOG "Updating kube-apiserver feature-gates in retrieved kubeadm-config"

    # Update api-server feature-gates
    sed -i \
    's/^\( *\)feature-gates:\s.*RemoveSelfLink=false/\1feature-gates: RemoveSelfLink=false/g' \
    "${KUBEADM_CONFIGMAP_TMPFILE}"
    RC=$?
    if [ "${RC}" == "0" ]; then
        LOG "Successfully updated kube-apiserver feature-gates in retrieved kubeadm-config"
    else
        ERROR "Failed to update kube-apiserver feature-gates in retrieved kubeadm-config with error code: [${RC}]"
        cleanup_and_exit ${RC}
    fi

    # update controller-manager feature-gates
    sed -i \
    '/feature-gates: TTLAfterFinished=true/d' "${KUBEADM_CONFIGMAP_TMPFILE}"
    RC=$?
    if [ "${RC}" == "0" ]; then
        LOG "Successfully updated controller-manager feature-gates in retrieved kubeadm-config"
    else
        # we need not gracefully exit here as failing to update this does not
        # make any difference to the k8s cluster functions as default value of
        # TTLAfterFinished is true
        ERROR "Failed to update controller-manager feature-gates in retrieved kubeadm-config with error code: [${RC}]"
    fi
}

function replace_configmap {

    output=$(kubectl --kubeconfig=/etc/kubernetes/admin.conf replace -f "${KUBEADM_CONFIGMAP_TMPFILE}" 2>&1)
    RC=$?
    if [ "${RC}" == "0" ]; then
        LOG 'Successfully replaced updated kubeadm configmap.'
    else
        # LP-1996546. kubectl replace expects replacing object to be latest version.
        # Although there is low chance that kubeadm-configmap is modified by other
        # process in between calls get_kubeadm_configmap and replace_configmap,
        # we should still check for that error. If it is the case, then we retry
        # modifying and replacing the newer version.
        if [[ ${output} == *"the object has been modified; please apply your changes to the latest version and try again" ]]; then
            LOG "kubeadm configmap is not the newest version."
        else
            ERROR "Failed to replace updated kubeadm configmap with error code: [${RC}]"
            cleanup_and_exit ${RC}
        fi
    fi
    return ${RC}
}

K8S_VERSION=$(kubectl version --output=yaml| grep -m1 -oP 'gitVersion: \K(\S+)')
LOG "k8s version: ${K8S_VERSION}"
counter=0
RETRIES=3
# Most errors during script execution result in exiting the script except one error.
# If kubeadm-configmap is modified by external process after it is
# retrieved in function get_kubeadm_configmap and before it is modified
# and replaced in the function replace_configmap, we should retry modifying
# and replacing the latest version.
until  [ ${counter} -gt ${RETRIES} ]; do
    get_kubeadm_configmap
    if [[ "${K8S_VERSION}" == "v1.21.8" ]]; then
        update_feature_gates_v1_22
    elif [[ "${K8S_VERSION}" == "v1.23.1" ]]; then
        update_feature_gates_service_param_v1_24
        update_kube_extra_config_bootstrap_v1_24
    else
        LOG "No update required for kubeadm configmap"
        break
    fi
    replace_configmap
    if [ "$?" == "0" ]; then
        break
    else
        LOG "Retrying to update the configmap..."
        counter=$(( counter+1 ))
    fi
done

cleanup_and_exit 0
