#!/bin/bash

##################################################################
# Licensed Materials - Property of IBM
#  5737-I23
#  Copyright IBM Corp. 2025, 2026. All Rights Reserved.
#  U.S. Government Users Restricted Rights:
#  Use, duplication or disclosure restricted by GSA ADP Schedule
#  Contract with IBM Corp.
##################################################################

# ---------------------------------------------------------------------------
# Prerequisites:
# Ensure that you are logged in to the OpenShift before executing this script.
# - OpenSearch credentials (OPENSEARCH_USERNAME, OPENSEARCH_PASSWORD)
# - OpenSearch URL (OPENSEARCH_URL)
# - jq (JSON processor)
# Usage:
# - set the variables below before running the script:
#   OPENSEARCH_URL="https://<opensearch-url>" OPENSEARCH_USERNAME="<opensearch-username>" OPENSEARCH_PASSWORD="<opensearch-password>" ENVIRONMENT="RUN" ./bai-data-metrics.sh
# -----------------------------------------------------------------------------

function getOScredentials() {
  OPENSEARCH_URL="${OPENSEARCH_URL:?}"
  [[ $OPENSEARCH_URL != "http"* ]] && OPENSEARCH_URL="https://${OPENSEARCH_URL}"
  if ! ping -o "$OPENSEARCH_URL" > /dev/null; then
      echo "OPENSEARCH_URL: $OPENSEARCH_URL unreachable"
      exit 1
  fi
  OPENSEARCH_USERNAME="${OPENSEARCH_USERNAME:?}"
  OPENSEARCH_PASSWORD="${OPENSEARCH_PASSWORD:?}"
  if [[ $(curlHEAD "") != 200 ]]; then
    echo "Invalid OpenSearch credentials"
    exit 2
  fi
  echo "OS URL: ${OPENSEARCH_URL}"
}

# "macros" to simplify code reading
function curlGET() {
  local endpoint="$1"
  curl -s -u "$OPENSEARCH_USERNAME:$OPENSEARCH_PASSWORD" -k "${OPENSEARCH_URL}/${endpoint}"
}

function curlPOST() {
  local endpoint="$1"
  local data="$2"
  curl -s -X POST -u "$OPENSEARCH_USERNAME:$OPENSEARCH_PASSWORD" -k "${OPENSEARCH_URL}/${endpoint}" -H 'Content-Type: application/json' -d "$data"
}

function curlHEAD() {
  # used to check whether an index exists 
  # prints 404 or 200
  curl -s --head -w '%{response_code}\n' -o /dev/null -u "${OPENSEARCH_USERNAME:?}:${OPENSEARCH_PASSWORD:?}" --insecure --url "${OPENSEARCH_URL:?}/$1"
}

function curlPUT() {
  local endpoint="$1"
  local data="$2"
  curl -s -X PUT -u "$OPENSEARCH_USERNAME:$OPENSEARCH_PASSWORD" -k "${OPENSEARCH_URL}/$endpoint" -H 'Content-Type: application/json' -d "$data"
}

# To check and create the data metrics tracking index with the appropriate mapping if it doesn't exist
function setupIndex() {
  if [[ $(curlHEAD "icp4ba-bai-datametrics-tracking-ibm-bai") != 200 ]]; then
    echo "Creating Index for Data Metrics Tracking"
    curlPUT "icp4ba-bai-datametrics-tracking-ibm-bai" '{
      "mappings": {
        "dynamic": true,
        "properties": {
          "id": {
            "type": "keyword"
          },
          "timestamp": {
            "type": "date"
          },
          "monitoring_source": {
            "type": "keyword"
          },
          "index": {
            "type": "keyword"
          },
          "number_of_documents": {
            "type": "long"
          },
          "global_storage_size_bytes": {
            "type": "long"
          },
          "global_storage_size_megabytes": {
            "type": "double"
          },
          "average_document_size_bytes": {
            "type": "long"
          },
          "environment": {
            "type": "keyword"
          }
        }
      }
    }'
  fi
}

# To create the BAI Data Metrics tracking monitoring source if it doesn't exist
function createMonitoringSource() {
  local monitoring_source_payload='{
    "id": "bai-data-metrics",
    "name": "bai-data-metrics",
    "monitoringSources": [
      {
        "id": "BAI Data Metrics",
        "elasticsearchIndex": "icp4ba-bai-datametrics-tracking-ibm-bai",
        "fields": [
          {
            "field": "index",
            "labelField": "monitoring_source"
          }
        ],
        "name": "BAI Data Metrics"
      }
    ]
  }'
  if [[ $(curlHEAD "icp4ba-bai-store-monitoring-sources/_doc/bai-data-metrics") != 200 ]]; then
    echo "Creating BAI data metrics Monitoring Source"
    curlPOST "icp4ba-bai-store-monitoring-sources/_doc/bai-data-metrics" "$monitoring_source_payload"
  fi
}

# To fetch monitoring sources from the records in the monitoring-sources index
function fetchMonitoringSources() {
  local response
  # Array to store monitoring sources to be iterated 
  monitoring_sources=()
  response=$(curlGET "icp4ba-bai-store-monitoring-sources/_search?q=-_id:bai-data-metrics")
  # mapfile is better, but not portable by default on mac, so using the suggestion from shellcheck (SC2207) instead
  # mapfile -t monitoring_sources < <(jq -r '.hits.hits[] | ._source.monitoringSources[] | "\(.elasticsearchIndex)/\(.name)#"' <<< "$response")

  # build an array from all the hits, with monitoring source index and name in each array line, separated by a forward slash (/) for further parsing
  while IFS='' read -r line; do monitoring_sources+=("$line"); done < \
        <(jq -r '.hits.hits[] | ._source.monitoringSources[] | "\(.elasticsearchIndex)/\(.name)"' <<< "$response")
}

function printCSVfile {
  local csvfile
  csvfile="report.$ENVIRONMENT.$timestamp.csv"

  for line in "${report[@]}"
  do
    echo "$line" >> "$csvfile"
  done

  echo
  echo "CSV report saved to $csvfile"
  cat "$csvfile"
}

function computeNumberOfFields() {
  index=$1
  # the following jq query does the following:
  # it reads the mappings of the index, as a JSON file
  # it flattens the document, in an array [paths(scalars)]
  # it selects only the paths which includes 'properties' 3 levels above leaf level (which is only the case for attributes path) *| select(.[-3] == "properties")*
  # it removes 'mappings/properties' first 2 levels with *| .[2:]*, then removes the 'type' final level with *| .[:-1]*
  # it removes any intermediate occurences of properties in the remaining path (luckily it still works when the attribute is called properties, as the path still exists) *| map(select(. != "properties"))*
  # it then reconstitutes the paths as strings, joining the elements with dots to recreate a FQN *| map( join("."))*
  # it makes sure that attributes are uniquely represented, then it counts the elements in the array *| unique | length*
  curlGET "$index/_mapping" | \
     jq '[paths(scalars) | select(.[-3] == "properties")| .[3:] | .[:-1] | map(select(. != "properties"))] | map( join(".")) | unique | length'
}

function findWriteIndexOfAlias() {
  monitoring_source_alias=$1

  response=$(curlGET "_alias/$monitoring_source_alias")

  notalias=$(jq 'select( .status == 404) | true' <<< "$response" )
  if [[ "$notalias" == "true"  ]]; then
    # this is just an index
    echo "$monitoring_source_alias"
    return
  fi

  alias_with_single_index=$(jq 'length' <<< "$response" )
  if [[ "$alias_with_single_index" == "1"  ]]; then
    # the alias contains a single index, so we can use the alias
    echo "$monitoring_source_alias"
    return
  fi

  # return the only index with "is_write_index"
  jq -r '[paths(scalars) | select(.[-1] == "is_write_index") | .[0]][0]' <<< "$response" 
}

# compute the average document size in an index by sampling a limited set of documents 
# and adding the lengthes of their _source attribute
function sample_average_size() {
  local index="$1"
  local sample_count="$2"

  local query='{ 
        "query": { 
            "query_string": { 
            "query": "*" 
            }
        },
        "size": '$sample_count',
        "from": 0,
        "_source" : true,
        "sort": {
            "_script": {
            "type": "number",
            "script": {
                "source": "Math.random()",
                "lang": "painless"
            },
            "order": "asc"
            }
        }
    }'
  local actualsamplesize
  actualsamplesize=$(curlPOST "$index/_search" "$query" | jq '{ count : .hits.hits | length, size: .hits.hits | map( ._source | tostring | length ) | add }')

  # compute the average and round it to 1 decimal digit
  average=$(jq '.size / .count *  10 | ceil / 10' <<< "$actualsamplesize")
}

# To process each monitoring source, by : 
# - making sure it is not processed already (avoid counting things twice)
# - getting number of documents with the _stats API (other values not used anymore)
# - calling the sample_average_size function after having computed the size of the sample set 
# - estimating the global document size in bytes in the index by using the average size and the number of documents
# - converting this global size to megabytes
# - accumulating the global size into a total for all indices
# - building and POSTing a metrics document for that monitoring source to the data metrics tracking index

function processMonitoringSource() {
  local opensearchIndex=$1
  local name=$2
  local timestamp=$3

  # Check if the index has already been processed
  for processed_index in "${processed_indices[@]}"; do
    if [ "$processed_index" == "$opensearchIndex" ]; then
      echo "Skipping duplicate index $opensearchIndex"
      return
    fi
  done

  if [ -z "$opensearchIndex" ] || [ -z "$name" ]; then
    echo "Skipping due to missing Opensearch index or name"
    return
  fi

  echo "Processing monitoring source $name"

  local number_of_documents
  number_of_documents=$(curlGET "${opensearchIndex}/_count" | jq ' .count ')

  local global_storage_size_bytes=0
  local average_document_size_bytes=0

  if [ "$number_of_documents" != 0 ]; then
    local samplesize
    samplesize=$(jq 'fmin(. / 10 ; 1000) | ceil ' <<< "$number_of_documents" )
  # Run the sampling function
    sample_average_size "$opensearchIndex" "$samplesize"
    average_document_size_bytes=$average
    global_storage_size_bytes=$(jq -n "$average_document_size_bytes * $number_of_documents | ceil")
  fi

  local global_storage_size_megabytes
  global_storage_size_megabytes=$(jq -n --argjson b "$global_storage_size_bytes" '$b / 1048576 | (.*100 | round)/100')

  total_number_of_documents=$((total_number_of_documents + number_of_documents))
  total_storage_size=$((total_storage_size + global_storage_size_bytes))

  # Sum and mark the index as processed
  processed_indices+=("$opensearchIndex")

  local doc_id
  doc_id="process-$(uuidgen)"

  local json_payload
  json_payload=$(jq -n --arg id "$doc_id" --arg timestamp "$timestamp" --arg monitoring_source "$name" --arg index "$opensearchIndex" \
                       --argjson number_of_documents "$number_of_documents" \
                       --argjson global_storage_size_bytes "$global_storage_size_bytes" --argjson global_storage_size_megabytes "$global_storage_size_megabytes" \
                       --argjson average_document_size_bytes "$average_document_size_bytes" --arg environment "$ENVIRONMENT" '{
    id: $id,
    timestamp: $timestamp,
    monitoring_source: $monitoring_source,
    index: $index,
    number_of_documents: $number_of_documents,
    global_storage_size_bytes: $global_storage_size_bytes,
    global_storage_size_megabytes: $global_storage_size_megabytes,
    average_document_size_bytes: $average_document_size_bytes,
    environment: $environment
  }')

  report+=("$name, $number_of_documents, $global_storage_size_megabytes, $average_document_size_bytes")

  curlPOST "icp4ba-bai-datametrics-tracking-ibm-bai/_doc" "$json_payload" > /dev/null

  echo "Results for $name : $number_of_documents documents, of average size $average_document_size_bytes bytes, totalling $global_storage_size_bytes MB"

  # cherry on the cake : a means to know how many fields are used in the write index of an alias
  writeIndex=$(findWriteIndexOfAlias "$opensearchIndex")

  if [[ "$writeIndex" != "null" ]]; then
    numberOfFields=$(computeNumberOfFields "$writeIndex")
    echo "For $opensearchIndex, the write index is: $writeIndex and the number of fields in this index is : $numberOfFields"
  else
    echo "No write index for $opensearchIndex - cannot compute number of fields"
  fi

  echo
}

# To compute and send total values, by
# - computing a global average size (not as an average of averages)
# - converting the total size in megabytes
# - building and POSTing a document for totals
function sendTotalValues() {
  local total_timestamp
  total_timestamp="$1"

  if [ $total_number_of_documents -ne 0 ]; then
    total_average_size=$((total_storage_size / total_number_of_documents))
  else
    total_average_size=0
  fi
  total_storage_megasize=$(jq -n --argjson b "$total_storage_size" '$b / 1048576 | (.*100 | round)/100')

  local total_doc_id
  total_doc_id=$(uuidgen)

  local total_json_payload
  total_json_payload=$(jq -n --arg id "$total_doc_id" --arg timestamp "$total_timestamp" \
                             --arg monitoring_source "Totals" --arg index "totals" --argjson number_of_documents "$total_number_of_documents" \
                             --argjson global_storage_size_bytes "$total_storage_size" --argjson global_storage_size_megabytes "$total_storage_megasize" \
                             --argjson average_document_size_bytes "$total_average_size" --arg environment "$ENVIRONMENT" '{
    id: $id,
    timestamp: $timestamp,
    monitoring_source: $monitoring_source,
    index: $index,
    number_of_documents: $number_of_documents,
    global_storage_size_bytes: $global_storage_size_bytes,
    global_storage_size_megabytes: $global_storage_size_megabytes,
    average_document_size_bytes: $average_document_size_bytes,
    environment: $environment
  }')

  report+=("Totals, $total_number_of_documents, $total_storage_megasize, $total_average_size")

  curlPOST "icp4ba-bai-datametrics-tracking-ibm-bai/_doc" "$total_json_payload" > /dev/null

  echo "Document for Totals: $total_json_payload"
}

# To run the full sequence :
# - initializations of variables and of indices and special monitoring source
# - listing the relevant monitoring sources
# - process them iteratively with processMonitoringSource
# - send the records with the totals
# - optionally, write the totals in a CSV file

function main() {
  filechoice=$1

  ENVIRONMENT=${ENVIRONMENT:?}

  total_number_of_documents=0
  total_storage_size=0

  # Array to track processed indices
  processed_indices=()

  getOScredentials

  setupIndex  

  createMonitoringSource

  report=("Monitoring Source, Documents, Storage (MB), Average Document Size (bytes)")

  fetchMonitoringSources

  # same timestamp for all measurements (to avoid clock thresholds to interfere with BPC display)
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  for i in "${!monitoring_sources[@]}"; do
     IFS='/' read -r elasticsearchIndex name <<< "${monitoring_sources[i]}"
     processMonitoringSource "$elasticsearchIndex" "$name" "$timestamp"
  done

  sendTotalValues "$timestamp"

  if [ "$filechoice" == "CSV" ]; then
    printCSVfile
  fi
}

# run the main function
main "$@"