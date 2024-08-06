#!/usr/bin/env bash

rm test.db
sqlite3 -init create_trips_db.sql test.db .quit
