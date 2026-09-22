const noop = () => {};

noop.enabled = () => false;
noop.extend = () => noop;

export default noop;
