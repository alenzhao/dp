require 'dp'

--[[command line arguments]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a Language Model on BillionWords dataset using SoftmaxTree')
cmd:text('Example:')
cmd:text('$> th languagemodel.lua --small --batchSize 512 ')
cmd:text('$> th languagemodel.lua --tiny --batchSize 512 ')
cmd:text('Options:')
cmd:option('--learningRate', 0.1, 'learning rate at t=0')
cmd:option('--maxOutNorm', 0, 'max norm each layers output neuron weights')
cmd:option('--momentum', 0, 'momentum')
cmd:option('--batchSize', 512, 'number of examples per batch')
cmd:option('--type', 'double', 'type: double | float | cuda')
cmd:option('--maxEpoch', 100, 'maximum number of epochs to run')
cmd:option('--maxTries', 30, 'maximum number of epochs to try to find a better local minima for early-stopping')
cmd:option('--dropout', false, 'apply dropout on hidden neurons, requires "nnx" luarock')

cmd:option('--contextSize', 5, 'number of words preceding the target word used to predict the target work')
cmd:option('--inputEmbeddingSize', 100, 'number of neurons per word embedding')

--[[ first hidden layer ]]--
cmd:option('--neuralSize', 200, 'number of hidden units used for first hidden layer (used when --convolution is not used)')
--or
cmd:option('--convolution', false, 'use a Convolution1D instead of Neural for the first hidden layer')
cmd:option('--convOutputSize', 200, 'number of output neurons of the convolutional kernel (outputFrameSize)')
cmd:option('--convKernelSize', 2, 'number of words considered by convolution')
cmd:option('--convKernelStride', 1, 'stride (step size) of the convolution')
cmd:option('--convPoolSize', 2, 'number of words max pooled after convolution')
cmd:option('--convPoolStride', 2, 'stride of the max pooling after the convolution') 

cmd:option('--outputEmbeddingSize', 100, 'number of hidden units at softmaxtree')

--[[ output layer ]]--
cmd:option('--softmaxtree', false, 'use the softmaxtree instead of the inefficient (full) softmax')

--[[ data ]]--
cmd:option('--small', false, 'use a small (1/30th) subset of the training set')
cmd:option('--tiny', false, 'use a tiny (1/100th) subset of the training set')
cmd:option('--trainEpochSize', 1000000, 'number of train examples seen between each epoch')
cmd:option('--validEpochSize', 100000, 'number of valid examples used for early stopping and cross-validation') 

cmd:text()
opt = cmd:parse(arg or {})
print(opt)


--[[data]]--
local train_file = 'train_data.th7' 
if opt.small then 
   train_file = 'train_small.th7'
elseif opt.tiny then 
   train_file = 'train_tiny.th7'
end

local datasource = dp.BillionWords{
   context_size = opt.contextSize, train_file = train_file
}

--[[Model]]--
if opt.dropout then
   require 'nnx'
end

print("Input to first hidden layer has "..
   opt.contextSize*opt.inputEmbeddingSize.." neurons.")

local hiddenModel, inputSize
if opt.convolution then
   print"Using convolution for first hidden layer"
   hiddenModel = dp.Convolution1D{
      input_size = opt.inputEmbeddingSize, 
      output_size = opt.convOutputSize,
      kernel_size = opt.convKernelSize,
      kernel_stride = opt.convKernelStride,
      pool_size = opt.convPoolSize,
      pool_stride = opt.convPoolStride,
      transfer = nn.Tanh(),
      dropout = opt.dropout and nn.Dropout() or nil
   }
   local nOutputFrame = hiddenModel:nOutputFrame(opt.contextSize)
   print("Convolution has "..nOutputFrame.." output Frames")
   inputSize = nOutputFrame*opt.convOutputSize
else
   hiddenModel = dp.Neural{
      input_size = opt.contextSize*opt.inputEmbeddingSize,
      output_size = opt.neuralSize, 
      transfer = nn.Tanh(),
      dropout = opt.dropout and nn.Dropout() or nil
   }
   inputSize = opt.neuralSize
end

print("Input to second hidden layer has size "..inputSize)

local softmax
if opt.softmaxtree then
   softmax = dp.SoftmaxTree{
      input_size = opt.outputEmbeddingSize, 
      hierarchy = datasource:hierarchy(),
      root_id = 880542,
      dropout = opt.dropout and nn.Dropout() or nil
   }
else
   print("Warning: you are using full SoftMax for last layer, which "..
      "is really slow (800,000 x outputEmbeddingSize multiply adds "..
      "per example. Try --softmaxtree instead.")
   softmax = dp.Neural{
      input_size = opt.outputEmbeddingSize,
      output_size = table.length(datasource:classes()),
      transfer = nn.SoftMax(),
      dropout = opt.dropout and nn.Dropout() or nil
   }
end

mlp = dp.Sequential{
   models = {
      dp.Dictionary{
         dict_size = datasource:vocabularySize(),
         output_size = opt.inputEmbeddingSize
      },
      hiddenModel,
      dp.Neural{
         input_size = inputSize, 
         output_size = opt.outputEmbeddingSize, 
         transfer = nn.Tanh(),
         dropout = opt.dropout and nn.Dropout() or nil
      },
      softmax
   }
}

--[[GPU or CPU]]--
if opt.type == 'cuda' then
   print"Using CUDA"
   require 'cutorch'
   require 'cunn'
   mlp:cuda()
end

--[[Propagators]]--
train = dp.Optimizer{
   loss = opt.softmaxtree and dp.TreeNLL() or dp.NLL(),
   visitor = { -- the ordering here is important:
      --dp.Momentum{momentum_factor = opt.momentum},
      dp.Learn{
         learning_rate = opt.learningRate, 
         observer = dp.LearningRateSchedule{
            schedule = {[200]=0.01, [400]=0.001}
         }
      }--,
      --dp.MaxNorm{max_out_norm = opt.maxOutNorm}
   },
   feedback = dp.Perplexity(),  
   sampler = dp.Sampler{ --shuffle sample takes too much mem
      epoch_size = opt.trainEpochSize, batch_size = opt.batchSize
   },
   progress = true
}
valid = dp.Evaluator{
   loss = opt.softmaxtree and dp.TreeNLL() or dp.NLL(),
   feedback = dp.Perplexity(),  
   sampler = dp.Sampler{
      epoch_size = opt.validEpochSize, batch_size = 1024
   },
   progress = true
}
test = dp.Evaluator{
   loss = opt.softmaxtree and dp.TreeNLL() or dp.NLL(),
   feedback = dp.Perplexity(),  
   sampler = dp.Sampler()
}

--[[Experiment]]--
xp = dp.Experiment{
   model = mlp,
   optimizer = train,
   validator = valid,
   tester = test,
   observer = {
      dp.FileLogger(),
      dp.EarlyStopper{max_epochs = opt.maxTries}
   },
   random_seed = os.time(),
   max_epoch = opt.maxEpoch
}

xp:run(datasource)
