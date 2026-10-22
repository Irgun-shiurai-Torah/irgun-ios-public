import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const validator = fileURLToPath(new URL('../.github/regression/validate_accounts.py',import.meta.url));
const accounts = {
  IRGUN_QA_EMAIL_1:'original@example.invalid',
  IRGUN_QA_EMAIL_2:'second@example.invalid',
  IRGUN_QA_EMAIL_3:'third@example.invalid',
  IRGUN_QA_SLOT:'2',
  IRGUN_TEST_EMAIL:'second@example.invalid',
  IRGUN_TEST_PASSWORD:'disposable-unit-test-password',
};
function run(changes={}) {
  const env = {...accounts,...changes};
  const result = spawnSync('python3',[validator],{encoding:'utf8',
    env:{PATH:process.env.PATH,...env}});
  assert.ifError(result.error);
  const output = result.stdout + result.stderr;
  for (const value of Object.entries(env).filter(([key,value])=>
    (key.includes('EMAIL') || key.includes('PASSWORD')) && value.trim()).map(([,value])=>value)) {
    assert.ok(!output.includes(value),'Preflight must never print a credential value');
  }
  return {status:result.status,output};
}

test('isolated QA slot 2 accepts its selected credentials',()=> {
  assert.equal(run().status,0);
});
test('isolated QA slot 3 accepts only its own credentials',()=> {
  assert.equal(run({IRGUN_QA_SLOT:'3',IRGUN_TEST_EMAIL:accounts.IRGUN_QA_EMAIL_3}).status,0);
  assert.equal(run({IRGUN_QA_SLOT:'3'}).status,1);
});
test('isolated QA preflight rejects the original account reused under a new lock',()=> {
  const result = run({IRGUN_QA_EMAIL_2:' ORIGINAL@EXAMPLE.INVALID ',
    IRGUN_TEST_EMAIL:'original@example.invalid'});
  assert.equal(result.status,1);
  assert.match(result.output,/different accounts/);
});
test('isolated QA preflight rejects the same account in both parallel device slots',()=> {
  const result = run({IRGUN_QA_EMAIL_3:accounts.IRGUN_QA_EMAIL_2});
  assert.equal(result.status,1);
  assert.match(result.output,/different accounts/);
});
test('isolated QA preflight rejects missing secrets without falling back to the original account',()=> {
  for (const key of ['IRGUN_QA_EMAIL_1','IRGUN_QA_EMAIL_2','IRGUN_QA_EMAIL_3',
    'IRGUN_TEST_EMAIL','IRGUN_TEST_PASSWORD']) {
    assert.equal(run({[key]:''}).status,1,key);
  }
});
test('isolated QA preflight rejects unrecognized account slots',()=> {
  for (const slot of ['','1','4']) assert.equal(run({IRGUN_QA_SLOT:slot}).status,1);
});
