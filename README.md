# BAI Customer Usage Tracking Metrics

BAI collects and processes events from various Business Automation components, which are stored as timeseries and summary documents in OpenSearch. Over time, they consume disk storage, that OpenSearch APIs can report about, and that IT Observability tools like IBM Instana can monitor and alert about. But it may useful for BAI administrators or managers to know how many documents are stored in each OpenSearch index, and how large the source documents are, in total and in average. These metrics might be of interest to measure the usage of BAI in the organization, or for internal billing, etc.

This sample allows you to measure the size of documents stored in OpenSearch indices for BAI. Basically, a
shell script measures the quantity and size of documents in BAI monitoring source indices and stores the returned values into dedicated OpenSearch documents that can be monitored by BPC charts.

## Sub folders

This directory contains:
* **bai-data-metrics.sh** A script that measures data usage and stores the result in an OpenSearch document.
* **BAI Data Metrics Tracking.json** An example dashboard to import into BPC for visualizing the metrics.
* **BAI Data Metrics Tracking Dashboard.png** A reference image (located in the <code>images/</code> folder) showing the dashboard view after importing <code>BAI Data Metrics Tracking.json</code>

## Prerequisites

To run the script, you need the following tool:
* jq - The jq tool is available from this page: [https://stedolan.github.io/jq/download/](https://stedolan.github.io/jq/download/)<br /><br />
You install jq on MacOS, on Linux, or on Windows Cygwin by running curl commands.
  * On MacOS:
  ```
  curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-osx-amd64 -o jq
  chmod +x jq
  sudo mv jq /usr/local/bin
  ```
  * On Linux:
  ```
  curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o jq
  chmod +x jq
  sudo mv jq /usr/local/bin
  ```
  * On Windows Cygwin:
  ```
  curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe -o jq.exe
  chmod +x jq.exe
  mv jq /usr/local/bin
  ```

## Accessing OpenSearch

To use the script, you must have access to OpenSearch.

  1. Log in to the OpenShift namespace where the IBM Cloud Pak for Business Automation platform is deployed.

  2. Retrieve the OpenSearch URL. Enter the namespace

```sh
export OPENSEARCH_URL="https://$(oc get routes opensearch-route -o jsonpath="{.spec.host}" -n $NAMESPACE)"
```

  3. Retrieve OpenSearch credentials based on your BAI Deployment version:
   - For All 24.0.0 / 24.0.1 versions:
```sh
export OPENSEARCH_SECRET=opensearch-ibm-elasticsearch-cred-secret
export OPENSEARCH_USERNAME=elastic
export OPENSEARCH_PASSWORD=$(oc extract secret/${OPENSEARCH_SECRET} --keys=elastic --to=- -n "$NAMESPACE" 2>/dev/null)
```
   - For version 25.0.0 or later:
```sh
export OPENSEARCH_SECRET=opensearch-admin-user
export OPENSEARCH_USERNAME=$(oc get "secret/$OPENSEARCH_SECRET" -o json -n "$NAMESPACE" | jq -r '.data|keys[0]')
export OPENSEARCH_PASSWORD=$(oc extract "secret/$OPENSEARCH_SECRET" --keys="$OPENSEARCH_USERNAME" --to=- -n "$NAMESPACE" 2>/dev/null)
```

## Calculate BAI Data Metrics

### Prerequisites

**Important**: Make sure that the path of the target installation directory contains no spaces.

### Procedure

1. Clone or download the GitHub project from https://github.com/icp4a/bai-data-usage-tracking-sample

2. Go to the directory of the cloned repository: <code>bai-usage-tracking-sample/</code>

3. Specify a tag in the <code>ENVIRONMENT</code> variable to associate with this measurement (e.g., "daily", "production", "test", "v1", ...). This tag can be used later as a filter in the dashboard.<br/>

4. Run the <code>bai-data-metrics.sh</code> script with the following options:<br/>
Note: Make sure OPENSEARCH_URL, OPENSEARCH_USERNAME, and OPENSEARCH_PASSWORD are already exported in your shell environment.
```
ENVIRONMENT="RUN" ./bai-data-metrics.sh
```
If the script executes successfully, you can verify it by checking the totals record in the output.<br/>

After an initialization phase, where a new index is created in OpenSearch to store the metrics, the script iterates over all the monitoring sources declared in the monitoring source index (which is generally an alias over a set of indices), and on each one, performs the following measurements:

* Counts the total number of documents in the index (depending on the monitoring source, documents are either timeseries events or stateful summaries).
* Evaluates the average size of the source documents stored in the index, by retrieving a sample of random documents in the index, and calculating the average size of documents in the sample.
* Estimates the cumulative size of the source documents in the index by multiplying the average document size by the total document count.

The script then creates a JSON record with the various measurements for each monitoring source, and writes it to the aforementioned metrics index with a measurement timestamp.
It finally creates a JSON record with the totals across the measured monitoring sources and writes it with the measurement timestamp and a new unique identifier, so that each measurement is kept and its evolution can be measured. In 25.0.1 and later versions, the dashboard can use the Latest aggregation on the totals records to display the current value.
It is recommended to run the script at regular intervals (for example, in a daily CronJob) for continuous monitoring of storage evolution over time.
### Visualize the Data in BPC

In BPC (Business Performance Center), you can view the data metrics.

* Log in to Business Performance Center in your browser.<br/>
**Note**: Read this page: https://www.ibm.com/docs/en/cloud-paks/cp-biz-automation/24.0.1?topic=specifics-accessing-business-automation-insights-services for more details about how to access to Business Performance Center.
  
* On the Dashboards page, click the Import button.
  
* Click Browse and select the file <code>BAI Data Metrics Tracking.json</code> from your cloned repository and click Import.
  
* After the import, open the dashboard titled <code>BAI Data Metrics Tracking</code> Template.
  
* You should now be able to view the dashboard, which should look like the following reference image: <code>BAI Data Metrics Tracking Dashboard.png</code>

**BAI Data Metrics Tracking Dashboard Overview**

The BAI Data Metrics Tracking dashboard provides insights into document count, storage usage, and data evolution trends from the monitoring sources. Below are the descriptions of each chart available in the dashboard:

* **Number of documents**: The KPI chart on its right shows the evolution of the total number of documents. It uses a configurable threshold and alert, so that you can know where the number of documents is compared to some limits.
* **Storage size**: Indicates the global storage usage (in megabytes) based on the most recent totals data selected with the Latest aggregation.
The KPI chart on its right shows the evolution of the global storage size. It uses a configurable set of thresholds and alerts, so that you can know where the current used storage stands compared to some limits.
* **Average document size**: Shows the average document size (in bytes) in the most recent data selected with the Latest aggregation (all monitoring sources combined)
The KPI chart on its right shows the evolution of the average storage size. It uses a configurable threshold so that you can know where the average document size is compared to your expectations.
* **Number of documents per monitoring source**: A pie chart visualizing the distribution of document counts across all monitoring sources. As documents are in general only added, the count keeps growing, so the chart displays the max value observed in the last day.
* **Storage size per index**: A pie chart representing how storage is divided among various monitoring sources.
* **Average Document Size per Index**: A bar chart showing average document size for each source over the past day.
* **Number of Docs over time**: Monitors the change in document volume per source over time using stacked bars in 15-minute intervals.
* **Storage Size over time**: A bar chart tracking the change in global storage size (in MB) per source over 15-minute intervals.
* **Average Document Size over time**: Displays the trend of average document sizes per source over time.
* **Recent Measurements Table**: A table listing recent measurements, including timestamp, source, document count, and storage metrics.
* **Count of measurements**: Shows the count of incoming data measurements over time, grouped by source.
