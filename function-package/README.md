# Ready-to-run Azure Function

This directory is the repository-contained deployment artifact. Administrators deploy it with `azd up`; Node.js and npm are not required on their workstation, and Azure does not restore packages from npm during deployment.

The readable TypeScript source is in [`../src`](../src). Contributors rebuild `index.cjs` with `npm run bundle` from that directory. Continuous integration rebuilds the file and fails if the committed artifact does not exactly match the reviewed source and lock file.
