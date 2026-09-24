"""
Cold-start only: when SSM_PARAMETER_PATH is set (Lambda), pulls every
parameter under that path into os.environ before anything else reads it.
Local/dev runs never set this var, so plain env vars keep working exactly
as before -- this module is a no-op there, and stays the only place that
touches AWS for config.
"""
import os

import boto3


def load_ssm_params():
    path = os.environ.get("SSM_PARAMETER_PATH")
    if not path:
        return

    client = boto3.client("ssm")
    next_token = None
    while True:
        kwargs = {"Path": path, "WithDecryption": True, "Recursive": True}
        if next_token:
            kwargs["NextToken"] = next_token
        result = client.get_parameters_by_path(**kwargs)
        for param in result.get("Parameters", []):
            name = param["Name"][len(path):].lstrip("/")
            if name:
                os.environ[name] = param["Value"]
        next_token = result.get("NextToken")
        if not next_token:
            break
