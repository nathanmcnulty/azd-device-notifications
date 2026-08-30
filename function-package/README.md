# Ready-to-run Azure Function

This directory is the repository-contained deployment artifact. Administrators deploy it with `azd up`; Node.js and npm are not required on their workstation, and Azure does not restore packages from npm during deployment.

The readable TypeScript source is in [`../src`](../src). Contributors rebuild `index.cjs` and its generated third-party notice, `index.cjs.LEGAL.txt`, with `npm run bundle` from that directory. Continuous integration rebuilds both files and fails if either differs from the reviewed source and lock file. Deployment includes both files in the Function ZIP.
