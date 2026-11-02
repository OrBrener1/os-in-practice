CC     = gcc
CFLAGS = -Wall -Wextra -pedantic -std=c11 -O2

channels: channels.c
	$(CC) $(CFLAGS) -o $@ channels.c

test: channels
	python3 examples/run_demo.py
	bash tests/run_tests.sh

clean:
	rm -f channels

.PHONY: test clean
