CC     = gcc
CFLAGS = -Wall -Wextra -pedantic -std=c11

scheduler: scheduler.c
	$(CC) $(CFLAGS) -o $@ scheduler.c

test: scheduler
	python3 examples/run_demo.py
	bash tests/run_tests.sh

clean:
	rm -f scheduler

.PHONY: test clean
