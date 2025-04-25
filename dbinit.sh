#!/bin/bash
##
## A helper script used to setup and takedown a Mongo DB for unit tests.
##
# Make sure to use the correct mongo binaries
PATH=`m path`:$PATH

#
# Output usage
#
function usage () {
    cat <<EOT
`basename $0` is a helper script used to setup and takedown a MongoDB
for unit tests.

Usage: `basename $0` [OPTIONS] COMMAND MONGODB_VERSION

Options:
    -v            increase verbosity
    -a            starts db with authentication enabled
    -h            prints help

Supported commands:
    init          sets up and starts database
    check         checks to see if database is running
    clean         stops and tears down database

Mongo DB Binary Versions:
    2.6.x
    3.0.x
    3.2.x
EOT
}

# Check usage
if [ $# -lt 1 ];  then
    usage
    exit 1
fi

# Handle options
while getopts ":avh" opt; do
    case ${opt} in
        a)
            USE_AUTH=1
            ;;
        v)
            VERBOSE=1
            ;;
        h)
            usage
            exit
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))


#
# Initializes the DB with auth users.
# All connections will use authentication.
#
function initdb () {
    checkit=`nc -z localhost 27017`
    if [ $? -eq 0 ]; then
        echo "mongodb is still running, exiting"
        exit 1
    fi

    if [ -e "/tmp/test-data" ]; then
        rm -rf /tmp/test-data
    fi

    # Switch to correct version of Mongo DB
    # Requires dependency mongodb-version-manager
    # Be sure to `npm install` beforehand.
    m use ${MONGODB_VERSION}

    mkdir -p /tmp/test-data
    mongod --dbpath /tmp/test-data --bind_ip 127.0.0.1 > /dev/null 2>&1 &

    until nc -z localhost 27017; do
        echo "Starting mongod..."
        sleep 1
    done

    if [ -n "${USE_AUTH}" ]; then
        echo "Creating admin user..."
        root_user_cmd='{user:"myadmin", pwd:"pass1234", roles:["root"]}'
        mongo admin --eval "db.createUser(${root_user_cmd})" > /dev/null 2>&1

        test_user_cmd='{user:"myadmin", pwd:"pass1234", roles:["readWrite"]}'
        echo "Creating user for humblejs_test database..."
        mongo humblejs_test --eval "db.createUser(${test_user_cmd})" \
            > /dev/null 2>&1
        echo "Stopping mongod..."
        mongo admin --eval 'db.shutdownServer()' > /dev/null 2>&1

        sleep 2

        mongod --dbpath /tmp/test-data --bind_ip 127.0.0.1 --auth \
            > /dev/null 2>&1 &
        until nc -z localhost 27017; do
            echo "Starting mongod with auth enabled..."
            sleep 1
        done
    fi

    echo "Done"
}

#
# Stops DB and cleans up entire database directory.
#
function cleandb () {
    # Switch to correct version of Mongo DB
    # Requires dependency mongodb-version-manager
    # Be sure to `npm install` beforehand.
    m use ${MONGODB_VERSION}

    checkit=`nc -z localhost 27017`
    if [ $? -eq 0 ]; then
        echo "Stopping mongod..."
        # Double check to see if mongod was started with auth
        using_auth=`ps aux | grep mongo | grep auth`
        if [ -n "${using_auth}" ]; then
            mongo admin -u myadmin -p pass1234 --authenticationDatabase admin \
                --eval "db.shutdownServer()" > /dev/null 2>&1
        else
            mongo admin --eval "db.shutdownServer()" > /dev/null 2>&1
        fi

        sleep 2
    else
        echo "mongod is not running, exiting"
        exit
    fi

    if [ -e "/tmp/test-data" ]; then
        echo "Cleaning up dbpath..."
        rm -rf /tmp/test-data
    fi

    echo "Done"
}

function checkdb () {
    checkit=`nc -z localhost 27017`
    if [ $? -eq 0 ]; then
        echo "mongodb is running"
    else
        echo "mongodb is not running"
    fi
}

# Handle arguments
CMD=$1
MONGODB_VERSION=$2

if [ -z "${CMD}" ]; then
    echo "command is required"
    usage
    exit 1
fi

# Choose default as 4.x.x if db_version is not given
if [ -z "${MONGODB_VERSION}" ]; then
    MONGODB_VERSION="4.x.x"
fi

# Print out settings for debugging
if [ -n "${VERBOSE}" ]; then
    cat <<EOT
Performing [${CMD}] for version MongoDB [${MONGODB_VERSION}]
Using auth: ${USE_AUTH:-0}
EOT
fi


# Handle commands
case ${CMD} in
    init)
        initdb
        ;;
    check)
        checkdb
        ;;
    clean)
        cleandb
        ;;
    *)
        echo "Unrecognized command: ${CMD}"
        usage
        ;;
esac

