# Ready-to-run Azure Function

This directory is the repository-contained deployment artifact. Administrators deploy it with `azd up`; Node.js and npm are not required on their workstation, and Azure does not restore packages from npm during deployment.

The readable TypeScript source is in [`../src`](../src). Contributors run `npm run bundle` from that directory to rebuild `index.cjs`, esbuild's supplemental `index.cjs.LEGAL.txt`, the complete `THIRD-PARTY-NOTICES.txt`, and the deployment copy of `UNLICENSE.txt`. Continuous integration fails if any generated artifact differs from the reviewed source, installed dependency licenses, or lock file. Deployment includes all four files in the Function ZIP.
