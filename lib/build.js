var lines = require('readline').createInterface(process.stdin, process.stdout);
var Skew = require('./skew-api.min');
var fs = require('fs');

lines.on('line', function(line) {
  try {
    var json = JSON.parse(line);
    if (json.type === 'compile') {
      json.inputs = json.inputs.map(function(input) {
        return {
          name: input,
          contents: fs.readFileSync(input, 'utf8'),
        };
      });
    }
    process.stdout.write(JSON.stringify(Skew.message(json)) + '\n');
  } catch (e) {
    process.stderr.write(JSON.stringify((e && e.stack || e) + '') + '\n');
  }
});
