Integration Tests for MySQL Native
==================================

This sub-project is intended for proving the functionality of the project against a database instance.

## Running locally

A docker-compose.yml is supplied for convenience when testing locally. It's preconfigured to use the same username/password that is used during CI

To run tests on your machine, presuming docker is installed, simply run:

```
$ docker-compose up --detach
```

Then from within this directory ("tests") either run `dub` or `dub --config=use-vibe`. The tests can be run repeatedly as they add/remove tables appropriately.

Once you are finished, tear down the docker instance

```
$ docker-compose down
```