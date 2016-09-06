FROM fpco/stack-run:latest
MAINTAINER nstack@nstack.com

# copy the stack-installed bin
COPY ./bin/ /usr/local/bin/

# default entrypoint and cmd-line arg
ENTRYPOINT ["/usr/local/bin/github-events-amqp-source", "--amqp-exchange=githubevents"]
# CMD []


