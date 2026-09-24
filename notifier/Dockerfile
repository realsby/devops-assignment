# AWS's own base image + build pattern for a Lambda container image.
# CMD names the handler (module.function); the Lambda Runtime Interface
# Client baked into this base image is what calls it in real Lambda.
# Locally, compose overrides the entrypoint to run the polling loop
# (main()) instead — see the `notifier` service in docker-compose.yml.
FROM public.ecr.aws/lambda/python:3.13

COPY requirements.txt ${LAMBDA_TASK_ROOT}
RUN pip install --no-cache-dir -r requirements.txt --target "${LAMBDA_TASK_ROOT}"

COPY notifier.py load_ssm_params.py ${LAMBDA_TASK_ROOT}

CMD ["notifier.handler"]
