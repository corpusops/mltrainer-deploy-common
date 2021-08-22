#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import absolute_import, division, print_function

import sys
import os
import mlflow

from mlflow.tracking import MlflowClient

from mlflow.entities.model_registry.model_version_status import ModelVersionStatus


MODEL_NAME = os.environ['MODEL_NAME']
SKIP_MODEL = bool(os.environ.get('SKIP_MODEL'))

STAGE = os.environ.get('STAGE', 'Production')
MODEL_STAGE = os.environ.get('MODEL_STAGE', STAGE)

MODEL = os.environ.get('MODEL', f'./data/reference/{MODEL_NAME}')

# Wait until the model is ready
def wait_until_ready(client, model_name, model_version):
  for _ in range(10):
    model_version_details = client.get_model_version(
      name=model_name, version=model_version)
    status = ModelVersionStatus.from_string(model_version_details.status)
    print("Model status: %s" % ModelVersionStatus.to_string(status))
    if status == ModelVersionStatus.READY:
        break
    time.sleep(1)


def upload(client, PATH, NAME, STAGE):
    with mlflow.start_run():
        mlflow.tensorflow.log_model(tf_saved_model_dir=PATH,
                        tf_meta_graph_tags=None,
                        artifact_path='model',
                        tf_signature_def_key="serving_default")
        version = mlflow.register_model(
            mlflow.get_artifact_uri('model'), NAME)
        wait_until_ready(client, NAME, version.version)
        client.transition_model_version_stage(
            name=NAME, version=version.version, stage=STAGE)


def main():
    client = MlflowClient()
    if not SKIP_MODEL:
        upload(client, MODEL, MODEL_NAME, MODEL_STAGE)


if __name__ == '__main__':
    main()
# vim:set et sts=4 ts=4 tw=80:

