
.import google_transit/trips.txt --csv trips
.import google_transit/routes.txt --csv routes
.import google_transit/stops.txt --csv stops
.import google_transit/stop_times.txt --csv stop_times

CREATE INDEX stop_times_index ON stop_times(stop_id);
CREATE INDEX stop_times_trip_index ON stop_times(trip_id);
CREATE INDEX stops_index ON stops(stop_id);
CREATE INDEX trips_index ON trips(trip_id);
CREATE INDEX trips_route_index ON trips(route_id);
CREATE INDEX route_index ON routes(route_id);
