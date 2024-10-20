# Sentry Self-Hosted for Docker Swarm

## What is Sentry

## Why this repo exists

## Installation

Use one of the templates provided or fork and roll your own

## Developing

From the root of this project, run these commands:

1) Create the development data directory
    ```
    mkdir -p ./tmp/data/sentry
    ```

2) Create a `.env` file
    ```
    cp -v .env.example .env
    ```

3) Modify the `.env` file with the path to the development data directory
    ```
    sed -i "s|^SENTRY_DATA_PATH=.*|SENTRY_DATA_PATH=${PWD:?}/tmp/data/sentry|" .env
    ```

4) Create the custom docker network.
    ```
    sudo docker network create sentry-private
    ```

5) Build the docker image.
    ```
    sudo docker compose build
    ```

6) Modify any additional config options in the `.env` file.

7) Run the dev compose stack
    ```
    sudo docker compose up -d
    ```
