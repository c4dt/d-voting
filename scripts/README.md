# Scripts for running D-voting locally

The following scripts are available to configure and run D-voting locally.
They should be called in this order:

- `run_local.sh` - sets up a complete system with 4 nodes, the db, the authentication-server,
  and the frontend.
  The script runs only the DB in a docker environment, all the rest is run directly on the machine.
  This allows for easier debugging and faster testing of the different parts, mainly the
  authentication-server, but also the frontend.
  For debugging Dela, you still need to re-run everything.
- `local_proxies.sh` needs to be run once after the `run_local.sh` script
- `local_forms.sh` creates a new form and prints its ID

Every script must be called from the root of the repository:

```bash
./scripts/run_local.sh
./scripts/local_proxies.sh
./scripts/local_forms.sh
```

The following script is only called by the other scripts:

- `local_login.sh` logs into the frontend and stores the cookie

## Simulating an EPFL election

It seems that from time to time an EPFL election goes wrong :(
Here is what you need to do to run it locally:

- Get a copy of the `llmdproxies` directory from the backend and copy it to
`epfl-nodes/lmdproxies`. Take care about the new name `lmdproxies`, which has only one 'l'!
- Get a copy of the `/var/lib/postgresql/data` directory from the backend and copy it to
`epfl-nodes/postgresql`
- Get a copy of all the `/data` directories of the nodes and copy them to
`epfl-nodes/node-[1234]`
- Inspect the backend docker with `docker inspect backend | grep KEY` and copy the
two keys into `epfl-nodes/keypair` as `PUBLIC_KEY=` and `PRIVATE_KEY=`

Install [devbox](https://www.jetify.com/docs/devbox/installing_devbox/) and run it, then
add the dela directory with the appropriate branch:

```bash
devbox shell
git clone https://github.com/c4dt/dela -b run_epfl_dvoting_locally
echo "redirect go.dedis.ch/dela => ./dela"
```

Once that is done, make sure that the `epfl-nodes` directory is correctly set up:

```
# tree epfl-nodes
epfl-nodes
├── keypair
├── lmdbproxies
│   ├── data.mdb
│   └── lock.mdb
├── node-1
│   ├── access.json
│   ├── dela.db
│   └── private.key
├── node-2
│   ├── access.json
│   ├── dela.db
│   └── private.key
├── node-3
│   ├── access.json
│   ├── dela.db
│   └── private.key
├── node-4
│   ├── access.json
│   ├── dela.db
│   └── private.key
└── postgresql
    ├── PG_VERSION
    ├── base
    │   ├── 1
...
```

Then you can run the simulation with the following command:

```bash
./scripts/run_local.sh simulate
```

It takes 1-2 minutes to set up, then the browser should launche, or go to
https://localhost:3000
and login. Then choose `Change SCIPER` in the login icon, and enter the SCIPER of one
of the owners of the election.
Now you should be able to interact with the election like any other owner.

Have fun debugging!
