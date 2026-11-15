const {test} = require('node:test'); const assert = require('node:assert/strict');
test('authority', {skip: false}, () => { assert.equal(1, 2, 'authority must remain NEW'); });
