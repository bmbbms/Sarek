#!/usr/bin/env nextflow

/*
vim: syntax=groovy
-*- mode: groovy;-*-
kate: syntax groovy; space-indent on; indent-width 2;
================================================================================
=                                 S  A  R  E  K                                =
================================================================================
 New Germline (+ Somatic) Analysis Workflow. Started March 2016.
--------------------------------------------------------------------------------
 @Authors
 Sebastian DiLorenzo <sebastian.dilorenzo@bils.se> [@Sebastian-D]
 Jesper Eisfeldt <jesper.eisfeldt@scilifelab.se> [@J35P312]
 Phil Ewels <phil.ewels@scilifelab.se> [@ewels]
 Maxime Garcia <maxime.garcia@scilifelab.se> [@MaxUlysse]
 Szilveszter Juhos <szilveszter.juhos@scilifelab.se> [@szilvajuhos]
 Max Käller <max.kaller@scilifelab.se> [@gulfshores]
 Malin Larsson <malin.larsson@scilifelab.se> [@malinlarsson]
 Marcel Martin <marcel.martin@scilifelab.se> [@marcelm]
 Björn Nystedt <bjorn.nystedt@scilifelab.se> [@bjornnystedt]
 Pall Olason <pall.olason@scilifelab.se> [@pallolason]
 Pelin Sahlén <pelin.akan@scilifelab.se> [@pelinakan]
--------------------------------------------------------------------------------
 @Homepage
 http://opensource.scilifelab.se/projects/sarek/
--------------------------------------------------------------------------------
 @Documentation
 https://github.com/SciLifeLab/Sarek/README.md
--------------------------------------------------------------------------------
 Processes overview
 - RunSamtoolsStats - Run Samtools stats on recalibrated BAM files
 - RunBamQC - Run qualimap BamQC on recalibrated BAM files
 - CreateIntervalBeds - Create and sort intervals into bed files
 - RunHaplotypecaller - Run HaplotypeCaller for Germline Variant Calling (Parallelized processes)
 - RunGenotypeGVCFs - Run HaplotypeCaller for Germline Variant Calling (Parallelized processes)
 - ConcatVCF - Merge results from HaplotypeCaller, MuTect1 and MuTect2
 - RunSingleStrelka - Run Strelka for Germline Variant Calling
 - RunSingleManta - Run Manta for Single Structural Variant Calling
 - RunBcftoolsStats - Run BCFTools stats on vcf files
================================================================================
=                           C O N F I G U R A T I O N                          =
================================================================================
*/

version = '1.3'

// Check that Nextflow version is up to date enough
// try / throw / catch works for NF versions < 0.25 when this was implemented
nf_required_version = '0.25.0'
try {
    if( ! nextflow.version.matches(">= ${nf_required_version}") ){
        throw GroovyException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version ${nf_required_version} required! You are running v${workflow.nextflow.version}.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please update Nextflow.\n" +
              "============================================================"
}

if (params.help) exit 0, helpMessage()
if (params.version) exit 0, versionMessage()
if (!isAllowedParams(params)) exit 1, "params unknown, see --help for more information"
if (!checkUppmaxProject()) exit 1, "No UPPMAX project ID found! Use --project <UPPMAX Project ID>"

// Default params:
// Such params are overridden by command line or configuration definitions

// GVCF are generated
params.noGVCF = false
// Reports are generated
params.noReports = false
// BAMQC is used
params.noBAMQC = false
// Run Sarek in onlyQC mode
params.onlyQC = false
// outDir is current directory
params.outDir = baseDir
// No sample is defined
params.sample = ''
// Step is variantcalling
step = 'variantcalling'
// Not testing
params.test = ''
// No tools to be used
params.tools = ''
// Params are defined in config files
params.containerPath = ''
params.repository = ''
params.tag = ''

tools = params.tools ? params.tools.split(',').collect{it.trim().toLowerCase()} : []

directoryMap = defineDirectoryMap()
referenceMap = defineReferenceMap()
stepList = defineStepList()
toolList = defineToolList()
nucleotidesPerSecond = 1000.0 // used to estimate variant calling runtime
gvcf = !params.noGVCF
reports = !params.noReports
onlyQC = params.onlyQC
verbose = params.verbose

if (!checkParameterExistence(step, stepList)) exit 1, 'Unknown step, see --help for more information'
if (step.contains(',')) exit 1, 'You can choose only one step, see --help for more information'
if (!checkReferenceMap(referenceMap)) exit 1, 'Missing Reference file(s), see --help for more information'
if (!checkParameterList(tools,toolList)) exit 1, 'Unknown tool(s), see --help for more information'

if (params.test && params.genome in ['GRCh37', 'GRCh38']) {
  referenceMap.intervals = file("$workflow.projectDir/repeats/tiny_${params.genome}.list")
}

// TODO
// MuTect and Mutect2 could be run without a recalibrated BAM (they support
// the --BQSR option), but this is not implemented, yet.
// TODO
// FreeBayes does not need recalibrated BAMs, but we need to test whether
// the channels are set up correctly when we disable it

tsvPath = ''
if (params.sample) tsvPath = params.sample
else tsvPath = "${params.outDir}/${directoryMap.recalibrated}/recalibrated.tsv"

// Set up the bamFiles channel

bamFiles = Channel.empty()
if (tsvPath) {
  tsvFile = file(tsvPath)
  bamFiles = extractBams(tsvFile)
} else exit 1, 'No sample were defined, see --help'

(patientGenders, bamFiles) = extractGenders(bamFiles)

/*
================================================================================
=                               P R O C E S S E S                              =
================================================================================
*/

startMessage()

if (verbose) bamFiles = bamFiles.view {
  "BAMs to process:\n\
  ID    : ${it[0]}\tStatus: ${it[1]}\tSample: ${it[2]}\n\
  Files : [${it[3].fileName}, ${it[4].fileName}]"
}

// assume input is recalibrated, ignore explicitBqsrNeeded
(bamForBamQC, bamForSamToolsStats, recalibratedBam, recalTables) = bamFiles.into(4)

recalTables = recalTables.map{ it + [null] } // null recalibration table means: do not use --BQSR

recalTables = recalTables.map { [it[0]] + it[2..-1] } // remove status

if (verbose) recalibratedBam = recalibratedBam.view {
  "Recalibrated BAM for variant Calling:\n\
  ID    : ${it[0]}\tStatus: ${it[1]}\tSample: ${it[2]}\n\
  Files : [${it[3].fileName}, ${it[4].fileName}]"
}

process RunSamtoolsStats {
  tag {idPatient + "-" + idSample}

  publishDir "${params.outDir}/${directoryMap.samtoolsStats}", mode: 'copy'

  input:
    set idPatient, status, idSample, file(bam), file(bai) from bamForSamToolsStats

  output:
    file ("${bam}.samtools.stats.out") into samtoolsStatsReport

  when: reports

  script:
  """
  samtools stats ${bam} > ${bam}.samtools.stats.out
  """
}

if (verbose) samtoolsStatsReport = samtoolsStatsReport.view {
  "SAMTools stats report:\n\
  File  : [${it.fileName}]"
}

process RunBamQC {
  tag {idPatient + "-" + idSample}

  publishDir "${params.outDir}/${directoryMap.bamQC}", mode: 'copy'

  input:
    set idPatient, status, idSample, file(bam), file(bai) from bamForBamQC

  output:
    file("${idSample}") into bamQCreport

  when: reports && !params.noBAMQC

  script:
  """
  qualimap --java-mem-size=${task.memory.toGiga()}G \
  bamqc \
  -bam ${bam} \
  -outdir ${idSample} \
  -outformat HTML
  """
}

if (verbose) bamQCreport = bamQCreport.view {
  "BamQC report:\n\
  Dir   : [${it.fileName}]"
}

// Here we have a recalibrated bam set, but we need to separate the bam files based on patient status.
// The sample tsv config file which is formatted like: "subject status sample lane fastq1 fastq2"
// cf fastqFiles channel, I decided just to add _status to the sample name to have less changes to do.
// And so I'm sorting the channel if the sample match _0, then it's a normal sample, otherwise tumor.
// Then combine normal and tumor to get each possibilities
// ie. normal vs tumor1, normal vs tumor2, normal vs tumor3
// then copy this channel into channels for each variant calling
// I guess it will still work even if we have multiple normal samples

// separate recalibrateBams by status
bamsNormal = Channel.create()
bamsTumor = Channel.create()

recalibratedBam
  .choice(bamsTumor, bamsNormal) {it[1] == 0 ? 1 : 0}

// Ascat, Strelka Germline & Manta Germline SV
bamsForAscat = Channel.create()
bamsForSingleManta = Channel.create()
bamsForSingleStrelka = Channel.create()

(bamsTumorTemp, bamsTumor) = bamsTumor.into(2)
(bamsNormalTemp, bamsNormal) = bamsNormal.into(2)
(bamsForAscat, bamsForSingleManta, bamsForSingleStrelka) = bamsNormalTemp.mix(bamsTumorTemp).into(3)

// Removing status because not relevant anymore
bamsNormal = bamsNormal.map { idPatient, status, idSample, bam, bai -> [idPatient, idSample, bam, bai] }

bamsTumor = bamsTumor.map { idPatient, status, idSample, bam, bai -> [idPatient, idSample, bam, bai] }

// We know that MuTect2 (and other somatic callers) are notoriously slow.
// To speed them up we are chopping the reference into smaller pieces.
// (see repeats/centromeres.list).
// Do variant calling by this intervals, and re-merge the VCFs.
// Since we are on a cluster, this can parallelize the variant call processes.
// And push down the variant call wall clock time significanlty.

process CreateIntervalBeds {
  tag {intervals.fileName}

  input:
    file(intervals) from Channel.value(referenceMap.intervals)

  output:
    file '*.bed' into bedIntervals mode flatten

  script:
  // If the interval file is BED format, the fifth column is interpreted to
  // contain runtime estimates, which is then used to combine short-running jobs
  if (intervals.getName().endsWith('.bed'))
    """
    awk -vFS="\t" '{
      t = \$5  # runtime estimate
      if (t == "") {
        # no runtime estimate in this row, assume default value
        t = (\$3 - \$2) / ${nucleotidesPerSecond}
      }
      if (name == "" || (chunk > 600 && (chunk + t) > longest * 1.05)) {
        # start a new chunk
        name = sprintf("%s_%d-%d.bed", \$1, \$2+1, \$3)
        chunk = 0
        longest = 0
      }
      if (t > longest)
        longest = t
      chunk += t
      print \$0 > name
    }' ${intervals}
    """
  else
    """
    awk -vFS="[:-]" '{
      name = sprintf("%s_%d-%d", \$1, \$2, \$3);
      printf("%s\\t%d\\t%d\\n", \$1, \$2-1, \$3) > name ".bed"
    }' ${intervals}
    """
}

bedIntervals = bedIntervals
  .map { intervalFile ->
    final duration = 0.0
    for (line in intervalFile.readLines()) {
      final fields = line.split('\t')
      if (fields.size() >= 5) duration += fields[4].toFloat()
      else {
        start = fields[1].toInteger()
        end = fields[2].toInteger()
        duration += (end - start) / nucleotidesPerSecond
      }
    }
    [duration, intervalFile]
  }.toSortedList({ a, b -> b[0] <=> a[0] })
  .flatten().collate(2)
  .map{duration, intervalFile -> intervalFile}

if (verbose) bedIntervals = bedIntervals.view {
  "  Interv: ${it.baseName}"
}

(bamsNormalTemp, bamsNormal, bedIntervals) = generateIntervalsForVC(bamsNormal, bedIntervals)
(bamsTumorTemp, bamsTumor, bedIntervals) = generateIntervalsForVC(bamsTumor, bedIntervals)

// HaplotypeCaller
bamsForHC = bamsNormalTemp.mix(bamsTumorTemp)
bedIntervals = bedIntervals.tap { intervalsTemp }
recalTables = recalTables
  .spread(intervalsTemp)
  .map { patient, sample, bam, bai, recalTable, intervalBed ->
    [patient, sample, bam, bai, intervalBed, recalTable] }

// re-associate the BAMs and samples with the recalibration table
bamsForHC = bamsForHC
  .phase(recalTables) { it[0..4] }
  .map { it1, it2 -> it1 + [it2[6]] }

bamsAll = bamsNormal.combine(bamsTumor)

// Since idPatientNormal and idPatientTumor are the same
// It's removed from bamsAll Channel (same for genderNormal)
// /!\ It is assumed that every sample are from the same patient
bamsAll = bamsAll.map {
  idPatientNormal, idSampleNormal, bamNormal, baiNormal, idPatientTumor, idSampleTumor, bamTumor, baiTumor ->
  [idPatientNormal, idSampleNormal, bamNormal, baiNormal, idSampleTumor, bamTumor, baiTumor]
}

// Manta and Strelka
(bamsForManta, bamsForStrelka, bamsAll) = bamsAll.into(3)

bamsTumorNormalIntervals = bamsAll.spread(bedIntervals)

// MuTect1, MuTect2, FreeBayes
(bamsFMT1, bamsFMT2, bamsFFB) = bamsTumorNormalIntervals.into(3)

process RunHaplotypecaller {
  tag {idSample + "-" + intervalBed.baseName}

  input:
    set idPatient, idSample, file(bam), file(bai), file(intervalBed), recalTable from bamsForHC //Are these values `ped to bamNormal already?
    set file(genomeFile), file(genomeIndex), file(genomeDict), file(dbsnp), file(dbsnpIndex) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex,
      referenceMap.genomeDict,
      referenceMap.dbsnp,
      referenceMap.dbsnpIndex
    ])

  output:
    set val("gvcf-hc"), idPatient, idSample, idSample, file("${intervalBed.baseName}_${idSample}.g.vcf") into hcGenomicVCF
    set idPatient, idSample, file(intervalBed), file("${intervalBed.baseName}_${idSample}.g.vcf") into vcfsToGenotype

  when: 'haplotypecaller' in tools && !onlyQC

  script:
  BQSR = (recalTable != null) ? "--BQSR $recalTable" : ''
  """
  java -Xmx${task.memory.toGiga()}g \
  -jar \$GATK_HOME/GenomeAnalysisTK.jar \
  -T HaplotypeCaller \
  --emitRefConfidence GVCF \
  -pairHMM LOGLESS_CACHING \
  -R ${genomeFile} \
  --dbsnp ${dbsnp} \
  ${BQSR} \
  -I ${bam} \
  -L ${intervalBed} \
  --disable_auto_index_creation_and_locking_when_reading_rods \
  -o ${intervalBed.baseName}_${idSample}.g.vcf
  """
}
hcGenomicVCF = hcGenomicVCF.groupTuple(by:[0,1,2,3])

if (!gvcf) hcGenomicVCF.close()

process RunGenotypeGVCFs {
  tag {idSample + "-" + intervalBed.baseName}

  input:
    set idPatient, idSample, file(intervalBed), file(gvcf) from vcfsToGenotype
    set file(genomeFile), file(genomeIndex), file(genomeDict), file(dbsnp), file(dbsnpIndex) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex,
      referenceMap.genomeDict,
      referenceMap.dbsnp,
      referenceMap.dbsnpIndex
    ])

  output:
    set val("haplotypecaller"), idPatient, idSample, idSample, file("${intervalBed.baseName}_${idSample}.vcf") into hcGenotypedVCF

  when: 'haplotypecaller' in tools && !onlyQC

  script:
  // Using -L is important for speed
  """
  java -Xmx${task.memory.toGiga()}g \
  -jar \$GATK_HOME/GenomeAnalysisTK.jar \
  -T GenotypeGVCFs \
  -R ${genomeFile} \
  -L ${intervalBed} \
  --dbsnp ${dbsnp} \
  --variant ${gvcf} \
  --disable_auto_index_creation_and_locking_when_reading_rods \
  -o ${intervalBed.baseName}_${idSample}.vcf
  """
}
hcGenotypedVCF = hcGenotypedVCF.groupTuple(by:[0,1,2,3])

// we are merging the VCFs that are called separatelly for different intervals
// so we can have a single sorted VCF containing all the calls for a given caller

vcfsToMerge = hcGenomicVCF.mix(hcGenotypedVCF)
if (verbose) vcfsToMerge = vcfsToMerge.view {
  "VCFs To be merged:\n\
  Tool  : ${it[0]}\tID    : ${it[1]}\tSample: [${it[3]}, ${it[2]}]\n\
  Files : ${it[4].fileName}"
}

process ConcatVCF {
  tag {variantCaller + "-" + idSampleNormal}

  publishDir "${params.outDir}/${directoryMap."$variantCaller"}", mode: 'copy'

  input:
    set variantCaller, idPatient, idSampleNormal, idSampleTumor, file(vcFiles) from vcfsToMerge
    file(genomeIndex) from Channel.value(referenceMap.genomeIndex)

  output:
    set variantCaller, idPatient, idSampleNormal, idSampleTumor, file("*.vcf.gz") into vcfConcatenated
    file("*.vcf.gz.tbi") into vcfConcatenatedTbi

  when: ( 'haplotypecaller' in tools || 'mutect1' in tools || 'mutect2' in tools || 'freebayes' in tools ) && !onlyQC

  script:
  if (variantCaller == 'haplotypecaller') outputFile = "${variantCaller}_${idSampleNormal}.vcf"
  else if (variantCaller == 'gvcf-hc') outputFile = "haplotypecaller_${idSampleNormal}.g.vcf"
  else outputFile = "${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf"

  """
  # first make a header from one of the VCF intervals
  # get rid of interval information only from the GATK command-line, but leave the rest
  FIRSTVCF=\$(ls *.vcf | head -n 1)
  sed -n '/^[^#]/q;p' \$FIRSTVCF | \
  awk '!/GATKCommandLine/{print}/GATKCommandLine/{for(i=1;i<=NF;i++){if(\$i!~/intervals=/ && \$i !~ /out=/){printf("%s ",\$i)}}printf("\\n")}' \
  > header

  # Get list of contigs from the FASTA index (.fai). We cannot use the ##contig
  # header in the VCF as it is optional (FreeBayes does not save it, for example)
  CONTIGS=(\$(cut -f1 ${genomeIndex}))

  # concatenate VCFs in the correct order
  (
    cat header

    for chr in "\${CONTIGS[@]}"; do
      # Skip if globbing would not match any file to avoid errors such as
      # "ls: cannot access chr3_*.vcf: No such file or directory" when chr3
      # was not processed.
      pattern="\${chr}_*.vcf"
      if ! compgen -G "\${pattern}" > /dev/null; then continue; fi

      # ls -v sorts by numeric value ("version"), which means that chr1_100_
      # is sorted *after* chr1_99_.
      for vcf in \$(ls -v \${pattern}); do
        # Determine length of header.
        # The 'q' command makes sed exit when it sees the first non-header
        # line, which avoids reading in the entire file.
        L=\$(sed -n '/^[^#]/q;p' \${vcf} | wc -l)

        # Then print all non-header lines. Since tail is very fast (nearly as
        # fast as cat), this is way more efficient than using a single sed,
        # awk or grep command.
        tail -n +\$((L+1)) \${vcf}
      done
    done
  ) | bgzip > ${outputFile}.gz
  tabix ${outputFile}.gz
  """
}

if (verbose) vcfConcatenated = vcfConcatenated.view {
  "Variant Calling output:\n\
  Tool  : ${it[0]}\tID    : ${it[1]}\tSample: [${it[3]}, ${it[2]}]\n\
  File  : ${it[4].fileName}"
}

process RunSingleStrelka {
  tag {idSample}

  publishDir "${params.outDir}/${directoryMap.strelka}", mode: 'copy'

  input:
    set idPatient, status, idSample, file(bam), file(bai) from bamsForSingleStrelka
    set file(genomeFile), file(genomeIndex) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex
    ])

  output:
    set val("singlestrelka"), idPatient, idSample,  file("*.vcf.gz"), file("*.vcf.gz.tbi") into singleStrelkaOutput

  when: 'strelka' in tools && !onlyQC

  script:
  """
  \$STRELKA_INSTALL_PATH/bin/configureStrelkaGermlineWorkflow.py \
  --bam ${bam} \
  --referenceFasta ${genomeFile} \
  --runDir Strelka

  python Strelka/runWorkflow.py -m local -j ${task.cpus}

  mv Strelka/results/variants/genome.*.vcf.gz \
    Strelka_${idSample}_genome.vcf.gz
  mv Strelka/results/variants/genome.*.vcf.gz.tbi \
    Strelka_${idSample}_genome.vcf.gz.tbi
  mv Strelka/results/variants/variants.vcf.gz \
    Strelka_${idSample}_variants.vcf.gz
  mv Strelka/results/variants/variants.vcf.gz.tbi \
    Strelka_${idSample}_variants.vcf.gz.tbi
  """
}

if (verbose) singleStrelkaOutput = singleStrelkaOutput.view {
  "Variant Calling output:\n\
  Tool  : ${it[0]}\tID    : ${it[1]}\tSample: ${it[2]}\n\
  Files : ${it[3].fileName}\n\
  Index : ${it[4].fileName}"
}

process RunSingleManta {
  tag {idSample + " - Single Diploid"}

  publishDir "${params.outDir}/${directoryMap.manta}", mode: 'copy'

  input:
    set idPatient, status, idSample, file(bam), file(bai) from bamsForSingleManta
    set file(genomeFile), file(genomeIndex) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex
    ])

  output:
    set val("singlemanta"), idPatient, idSample,  file("*.vcf.gz"), file("*.vcf.gz.tbi") into singleMantaOutput

  when: 'manta' in tools && status == 0 && !onlyQC

  script:
  """
  \$MANTA_INSTALL_PATH/bin/configManta.py \
  --bam ${bam} \
  --reference ${genomeFile} \
  --runDir Manta

  python Manta/runWorkflow.py -m local -j ${task.cpus}

  mv Manta/results/variants/candidateSmallIndels.vcf.gz \
    Manta_${idSample}.candidateSmallIndels.vcf.gz
  mv Manta/results/variants/candidateSmallIndels.vcf.gz.tbi \
    Manta_${idSample}.candidateSmallIndels.vcf.gz.tbi
  mv Manta/results/variants/candidateSV.vcf.gz \
    Manta_${idSample}.candidateSV.vcf.gz
  mv Manta/results/variants/candidateSV.vcf.gz.tbi \
    Manta_${idSample}.candidateSV.vcf.gz.tbi
  mv Manta/results/variants/diploidSV.vcf.gz \
    Manta_${idSample}.diploidSV.vcf.gz
  mv Manta/results/variants/diploidSV.vcf.gz.tbi \
    Manta_${idSample}.diploidSV.vcf.gz.tbi
  """
}

if (verbose) singleMantaOutput = singleMantaOutput.view {
  "Variant Calling output:\n\
  Tool  : ${it[0]}\tID    : ${it[1]}\tSample: ${it[2]}\n\
  Files : ${it[3].fileName}\n\
  Index : ${it[4].fileName}"
}

vcfForBCFtools = Channel.empty().mix(
  singleStrelkaOutput.map {
    variantcaller, idPatient, idSample, vcf, tbi ->
    [variantcaller, vcf[1]]
  },
  singleMantaOutput.map {
    variantcaller, idPatient, idSample, vcf, tbi ->
    [variantcaller, vcf[2]]
  })

process RunBcftoolsStats {
  tag {vcf}

  publishDir "${params.outDir}/${directoryMap.bcftoolsStats}", mode: 'copy'

  input:
    set variantCaller, file(vcf) from vcfForBCFtools

  output:
    file ("${vcf.baseName}.bcf.tools.stats.out") into bcfReport

  when: reports

  script:
  """
  bcftools stats ${vcf} > ${vcf.baseName}.bcf.tools.stats.out
  """
}

if (verbose) bcfReport = bcfReport.view {
  "BCFTools stats report:\n\
  File  : [${it.fileName}]"
}

bcfReport.close()

/*
================================================================================
=                               F U N C T I O N S                              =
================================================================================
*/

def sarekMessage() {
  // Display Sarek message
  log.info "Sarek ~ ${version} - " + this.grabRevision() + (workflow.commitId ? " [${workflow.commitId}]" : "")
}

def checkFileExtension(it, extension) {
  // Check file extension
  if (!it.toString().toLowerCase().endsWith(extension.toLowerCase())) exit 1, "File: ${it} has the wrong extension: ${extension} see --help for more information"
}

def checkParameterExistence(it, list) {
  // Check parameter existence
  if (!list.contains(it)) {
    println("Unknown parameter: ${it}")
    return false
  }
  return true
}

def checkParameterList(list, realList) {
  // Loop through all parameters to check their existence and spelling
  return list.every{ checkParameterExistence(it, realList) }
}

def checkParamReturnFile(item) {
  params."${item}" = params.genomes[params.genome]."${item}"
  return file(params."${item}")
}

def checkParams(it) {
  // Check if params is in this given list
  return it in [
    'ac-loci',
    'acLoci',
    'annotate-tools',
    'annotate-VCF',
    'annotateTools',
    'annotateVCF',
    'build',
    'bwa-index',
    'bwaIndex',
    'call-name',
    'callName',
    'contact-mail',
    'contactMail',
    'container-path',
    'containerPath',
    'containers',
    'cosmic-index',
    'cosmic',
    'cosmicIndex',
    'dbsnp-index',
    'dbsnp',
    'docker',
    'genome_base',
    'genome-dict',
    'genome-file',
    'genome-index',
    'genome',
    'genomeDict',
    'genomeFile',
    'genomeIndex',
    'genomes',
    'help',
    'intervals',
    'known-indels-index',
    'known-indels',
    'knownIndels',
    'knownIndelsIndex',
    'max_cpus',
    'max_memory',
    'max_time',
    'no-BAMQC',
    'no-GVCF',
    'no-reports',
    'noBAMQC',
    'noGVCF',
    'noReports',
    'only-QC',
    'onlyQC',
    'out-dir',
    'outDir',
    'params',
    'project',
    'push',
    'repository',
    'run-time',
    'runTime',
    'sample-dir',
    'sample',
    'sampleDir',
    'single-CPUMem',
    'singleCPUMem',
    'singularity',
    'step',
    'tag',
    'test',
    'tools',
    'total-memory',
    'totalMemory',
    'vcflist',
    'verbose',
    'version']
}

def checkReferenceMap(referenceMap) {
  // Loop through all the references files to check their existence
  referenceMap.every {
    referenceFile, fileToCheck ->
    checkRefExistence(referenceFile, fileToCheck)
  }
}

def checkRefExistence(referenceFile, fileToCheck) {
  if (fileToCheck instanceof List) return fileToCheck.every{ checkRefExistence(referenceFile, it) }
  def f = file(fileToCheck)
  // this is an expanded wildcard: we can assume all files exist
  if (f instanceof List && f.size() > 0) return true
  else if (!f.exists()) {
    log.info  "Missing references: ${referenceFile} ${fileToCheck}"
    return false
  }
  return true
}

def checkUppmaxProject() {
  // check if UPPMAX project number is specified
  return !(workflow.profile == 'slurm' && !params.project)
}

def checkExactlyOne(list) {
  final n = 0
  list.each{n += it ? 1 : 0}
  return n == 1
}

def defineDirectoryMap() {
  return [
    'recalibrated'     : 'Preprocessing/Recalibrated',
    'bamQC'            : 'Reports/bamQC',
    'bcftoolsStats'    : 'Reports/BCFToolsStats',
    'samtoolsStats'    : 'Reports/SamToolsStats',
    'ascat'            : 'VariantCalling/Ascat',
    'freebayes'        : 'VariantCalling/FreeBayes',
    'haplotypecaller'  : 'VariantCalling/HaplotypeCaller',
    'gvcf-hc'          : 'VariantCalling/HaplotypeCallerGVCF',
    'manta'            : 'VariantCalling/Manta',
    'mutect1'          : 'VariantCalling/MuTect1',
    'mutect2'          : 'VariantCalling/MuTect2',
    'strelka'          : 'VariantCalling/Strelka'
  ]
}

def defineReferenceMap() {
  if (!(params.genome in params.genomes)) exit 1, "Genome ${params.genome} not found in configuration"
  return [
    // loci file for ascat
    'acLoci'           : checkParamReturnFile("acLoci"),
    'dbsnp'            : checkParamReturnFile("dbsnp"),
    'dbsnpIndex'       : checkParamReturnFile("dbsnpIndex"),
    // cosmic VCF with VCF4.1 header
    'cosmic'           : checkParamReturnFile("cosmic"),
    'cosmicIndex'      : checkParamReturnFile("cosmicIndex"),
    // genome reference dictionary
    'genomeDict'       : checkParamReturnFile("genomeDict"),
    // FASTA genome reference
    'genomeFile'       : checkParamReturnFile("genomeFile"),
    // genome .fai file
    'genomeIndex'      : checkParamReturnFile("genomeIndex"),
    // intervals file for spread-and-gather processes
    'intervals'        : checkParamReturnFile("intervals")
  ]
}

def defineStepList() {
  return [
    'variantcalling'
  ]
}

def defineToolList() {
  return [
    'ascat',
    'freebayes',
    'haplotypecaller',
    'manta',
    'mutect1',
    'mutect2',
    'strelka'
  ]
}

def extractBams(tsvFile) {
  // Channeling the TSV file containing BAM.
  // Format is: "subject gender status sample bam bai"
  Channel
    .from(tsvFile.readLines())
    .map{line ->
      def list      = returnTSV(line.split(),6)
      def idPatient = list[0]
      def gender    = list[1]
      def status    = returnStatus(list[2].toInteger())
      def idSample  = list[3]
      def bamFile   = returnFile(list[4])
      def baiFile   = returnFile(list[5])

      checkFileExtension(bamFile,".bam")
      checkFileExtension(baiFile,".bai")

      [ idPatient, gender, status, idSample, bamFile, baiFile ]
    }
}

def extractGenders(channel) {
  def genders = [:]  // an empty map
  channel = channel.map{ it ->
    def idPatient = it[0]
    def gender = it[1]
    genders[idPatient] = gender

    [idPatient] + it[2..-1]
  }
  [genders, channel]
}

def generateIntervalsForVC(bams, intervals) {

  def (bamsNew, bamsForVC) = bams.into(2)
  def (intervalsNew, vcIntervals) = intervals.into(2)
  def bamsForVCNew = bamsForVC.combine(vcIntervals)
  return [bamsForVCNew, bamsNew, intervalsNew]
}

def grabRevision() {
  // Return the same string executed from github or not
  return workflow.revision ?: workflow.commitId ?: workflow.scriptId.substring(0,10)
}

def helpMessage() {
  // Display help message
  this.sarekMessage()
  log.info "    Usage:"
  log.info "       nextflow run SciLifeLab/Sarek --sample <file.tsv> [--step STEP] [--tools TOOL[,TOOL]] --genome <Genome>"
  log.info "       nextflow run SciLifeLab/Sarek --sampleDir <Directory> [--step STEP] [--tools TOOL[,TOOL]] --genome <Genome>"
  log.info "       nextflow run SciLifeLab/Sarek --test [--step STEP] [--tools TOOL[,TOOL]] --genome <Genome>"
  log.info "    --sample <file.tsv>"
  log.info "       Specify a TSV file containing paths to sample files."
  log.info "    --sampleDir <Directoy>"
  log.info "       Specify a directory containing sample files."
  log.info "    --test"
  log.info "       Use a test sample."
  log.info "    --step"
  log.info "       Option to start workflow"
  log.info "       Possible values are:"
  log.info "         mapping (default, will start workflow with FASTQ files)"
  log.info "         realign (will start workflow with non-realigned BAM files)"
  log.info "         recalibrate (will start workflow with non-recalibrated BAM files)"
  log.info "         variantcalling (will start workflow with recalibrated BAM files)"
  log.info "         annotate (will annotate Variant Calling output."
  log.info "         By default it will try to annotate all available vcfs."
  log.info "         Use with --annotateTools or --annotateVCF to specify what to annotate"
  log.info "    --noReports"
  log.info "       Disable QC tools and MultiQC to generate a HTML report"
  log.info "    --tools"
  log.info "       Option to configure which tools to use in the workflow."
  log.info "         Different tools to be separated by commas."
  log.info "       Possible values are:"
  log.info "         mutect1 (use MuTect1 for VC)"
  log.info "         mutect2 (use MuTect2 for VC)"
  log.info "         freebayes (use FreeBayes for VC)"
  log.info "         strelka (use Strelka for VC)"
  log.info "         haplotypecaller (use HaplotypeCaller for normal bams VC)"
  log.info "         manta (use Manta for SV)"
  log.info "         ascat (use Ascat for CNV)"
  log.info "         snpeff (use snpEff for Annotation of Variants)"
  log.info "         vep (use VEP for Annotation of Variants)"
  log.info "    --annotateTools"
  log.info "       Option to configure which tools to annotate."
  log.info "         Different tools to be separated by commas."
  log.info "       Possible values are:"
  log.info "         haplotypecaller (Annotate HaplotypeCaller output)"
  log.info "         manta (Annotate Manta output)"
  log.info "         mutect1 (Annotate MuTect1 output)"
  log.info "         mutect2 (Annotate MuTect2 output)"
  log.info "         strelka (Annotate Strelka output)"
  log.info "    --annotateVCF"
  log.info "       Option to configure which vcf to annotate."
  log.info "         Different vcf to be separated by commas."
  log.info "    --genome <Genome>"
  log.info "       Use a specific genome version."
  log.info "       Possible values are:"
  log.info "         GRCh37"
  log.info "         GRCh38 (Default)"
  log.info "         smallGRCh37 (Use a small reference (Tests only))"
  log.info "    --onlyQC"
  log.info "       Run only QC tools and gather reports"
  log.info "    --help"
  log.info "       you're reading it"
  log.info "    --verbose"
  log.info "       Adds more verbosity to workflow"
  log.info "    --version"
  log.info "       displays version number"
}

def isAllowedParams(params) {
  // Compare params to list of verified params
  final test = true
  params.each{
    if (!checkParams(it.toString().split('=')[0])) {
      println "params ${it.toString().split('=')[0]} is unknown"
      test = false
    }
  }
  return test
}

def minimalInformationMessage() {
  // Minimal information message
  log.info "Command Line: " + workflow.commandLine
  log.info "Profile     : " + workflow.profile
  log.info "Project Dir : " + workflow.projectDir
  log.info "Launch Dir  : " + workflow.launchDir
  log.info "Work Dir    : " + workflow.workDir
  log.info "Out Dir     : " + params.outDir
  log.info "TSV file    : ${tsvFile}"
  log.info "Genome      : " + params.genome
  log.info "Genome_base : " + params.genome_base
  log.info "Step        : " + step
  log.info "Tools       : " + tools.join(', ')
  log.info "Containers  :"
  if (params.repository) log.info "  Repository   : ${params.repository}"
  else log.info "  ContainerPath: " + params.containerPath
  log.info "  Tag          : " + params.tag
  log.info "Reference files used:"
  log.info "  acLoci      :\n\t" + referenceMap.acLoci
  log.info "  cosmic      :\n\t" + referenceMap.cosmic
  log.info "\t" + referenceMap.cosmicIndex
  log.info "  dbsnp       :\n\t" + referenceMap.dbsnp
  log.info "\t" + referenceMap.dbsnpIndex
  log.info "  genome      :\n\t" + referenceMap.genomeFile
  log.info "\t" + referenceMap.genomeDict
  log.info "\t" + referenceMap.genomeIndex
  log.info "  intervals   :\n\t" + referenceMap.intervals
}

def nextflowMessage() {
  // Nextflow message (version + build)
  log.info "N E X T F L O W  ~  version ${workflow.nextflow.version} ${workflow.nextflow.build}"
}

def returnFile(it) {
  // return file if it exists
  if (!file(it).exists()) exit 1, "Missing file in TSV file: ${it}, see --help for more information"
  return file(it)
}

def returnStatus(it) {
  // Return status if it's correct
  // Status should be only 0 or 1
  // 0 being normal
  // 1 being tumor (or relapse or anything that is not normal...)
  if (!(it in [0, 1])) exit 1, "Status is not recognized in TSV file: ${it}, see --help for more information"
  return it
}

def returnTSV(it, number) {
  // return TSV if it has the correct number of items in row
  if (it.size() != number) exit 1, "Malformed row in TSV file: ${it}, see --help for more information"
  return it
}

def startMessage() {
  // Display start message
  this.sarekMessage()
  this.minimalInformationMessage()
}

def versionMessage() {
  // Display version message
  log.info "Sarek"
  log.info "  version   : " + version
  log.info workflow.commitId ? "Git info    : ${workflow.repository} - ${workflow.revision} [${workflow.commitId}]" : "  revision  : " + this.grabRevision()
}

workflow.onComplete {
  // Display complete message
  this.nextflowMessage()
  this.sarekMessage()
  this.minimalInformationMessage()
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
  log.info "Error report: " + (workflow.errorReport ?: '-')
}

workflow.onError {
  // Display error message
  this.nextflowMessage()
  this.sarekMessage()
  log.info "Workflow execution stopped with the following message:"
  log.info "  " + workflow.errorMessage
}
