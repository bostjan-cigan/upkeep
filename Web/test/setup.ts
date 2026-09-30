// Tests run in a time zone with DST so calendar arithmetic is exercised across the changes.
process.env.TZ = 'Europe/Ljubljana'
import 'fake-indexeddb/auto'
