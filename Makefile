REBAR := $(shell which rebar)
ifeq ($(REBAR),)
  REBAR=./rebar
endif

all: deps compile

deps:
	$(REBAR) get-deps

compile:
	$(REBAR) compile

rel: deps mixpanel
	$(REBAR) clean compile generate

test:
	$(REBAR) eunit skip_deps=true

clean:
	$(REBAR) clean
