.. _gpufit-customization:

=============
Customization
=============

This sections explains how to add custom fit model functions and custom fit estimators within |GF|.
Functions calculating the estimator and model values are defined in CUDA header files using the CUDA C syntax.
For each function and estimator there exists a separate file. Therefore, to add an additional model or estimator a new
CUDA header file containing the new model or estimator function must be created and included in the library.

Please note, that in order to add a model function or estimator, it is necessary to rebuild the Gpufit library 
from source.  In future releases of Gpufit, it may be possible to include new fit functions or estimators at runtime.


Add a new fit model function
----------------------------

To add a new fit model, the model function itself as well as analytic expressions for its partial derivatives 
must to be known.  A function calculating the values of the model as well as a function calculating the 
values of the partial derivatives of the model, with respect to the model parameters and possible grid 
coordinates, must be implemented.

Additionally, a new model ID must be defined and included in the list of available model IDs, and the number 
of model parameters must be specified as well.

Detailed step by step instructions for adding a model function are given below.

1.	Define an additional model ID in file gpufit.h_
2.  Implement a CUDA device function within a newly created .cuh file according to the following template.

.. code-block:: cuda

    __device__ void ... (                                       // function name
        float const * parameters,
        int const n_fits,
        int const n_points,
        int const n_parameters,
        float * values,
        float * derivatives,
        int const chunk_index,
        char * user_info,
        std::size_t const user_info_size)
    {
        ///////////////////////////// indices /////////////////////////////
        int const n_fits_per_block = blockDim.x / n_points;
        int const fit_in_block = threadIdx.x / n_points;
        int const point_index = threadIdx.x - (fit_in_block*n_points);
        int const fit_index = blockIdx.x*n_fits_per_block + fit_in_block;

        ///////////////////////////// values //////////////////////////////
        float* current_value = &values[fit_index*n_points];
        float const * current_parameters = &parameters[fit_index*n_parameters];

        current_value[point_index] = ... ;                      // formula calculating fit model values

        /////////////////////////// derivatives ///////////////////////////
        float * current_derivative = &derivatives[fit_index * n_points*n_parameters];

        current_derivative[0 * n_points + point_index] = ... ;  // formula calculating derivative values with respect to parameters[0]
        current_derivative[1 * n_points + point_index] = ... ;  // formula calculating derivative values with respect to parameters[1]
        .
        .
        .
    }

This code can be used as a pattern, where the placeholders ". . ." must be replaced by user code which calculates model
function values and partial derivative values of the model function for a particular set of parameters. See for example linear_1d.cuh_.

3.	Include the newly created .cuh file in cuda_kernels.cu_
4.	Add an if branch in the CUDA global function ``cuda_calc_curve()`` in file cuda_kernels.cu_ to allow calling the added model function

.. code-block:: cpp

    if (model_id == GAUSS_1D)
        calculate_gauss1d
            (parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);
            .
            .
            .
    else if (model_id == ...)       // model ID
        ...                         // function name
            (parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);

Compare model_id with the defined model of the new model and call the calculate model values function of your model.

5.	Add a switch case in function set_number_of_parameters in file interface.cpp_

.. code-block:: cpp

    switch (model_id)
    {
        case GAUSS_1D:
            n_parameters_ = 4;
            break;
            .
            .
            .
        case ... :                  // model ID
            n_parameters_ = ... ;   // number of model parameters
            break;
        default:
            break;
    }

Add a new fit estimator
------------------------

To extend |GF| by additional estimators, three CUDA device functions must be defined and integrated.  The sections requiring modification are 
the functions which calculate the estimator function values, and its gradient and hessian values. Also, a new estimator ID must be defined.
Detailed step by step instructions for adding an additional estimator is given below.

1. Define an additional estimator ID in gpufit.h_
2. Implement three functions within a newly created .cuh file calculating :math:`\chi^2` values and
   its gradient and hessian according to the following template.

.. code-block:: cuda

    ///////////////////////////// Chi-square /////////////////////////////
    __device__ void ... (           // function name Chi-square
        volatile float * chi_square,
        int const point_index,
        float const * data,
        float const * value,
        float const * weight,
        int * state,
        char * user_info,
        std::size_t const user_info_size)
    {
        chi_square[point_index] = ... ;            // formula calculating Chi-square summands
    }

    ////////////////////////////// gradient //////////////////////////////
    __device__ void ... (           // function name gradient
        volatile float * gradient,
        int const point_index,
        int const parameter_index,
        float const * data,
        float const * value,
        float const * derivative,
        float const * weight,
        char * user_info,
        std::size_t const user_info_size)
    {
        gradient[point_index] = ... ;            // formula calculating summands of the gradient of Chi-square
    }

    ////////////////////////////// hessian ///////////////////////////////
    __device__ void ... (           // function name hessian
        double * hessian,
        int const point_index,
        int const parameter_index_i,
        int const parameter_index_j,
        float const * data,
        float const * value,
        float const * derivative,
        float const * weight,
        char * user_info,
        std::size_t const user_info_size)
    {
        *hessian += ... ;            // formula calculating summands of the hessian of Chi-square
    }

This code can be used as a pattern, where the placeholders ". . ." must be replaced by user code which calculates the estimator
and the hessian values of the estimator given. For a concrete example, see lse.cuh_.

3. Include the newly created .cuh file in cuda_kernels.cu_

.. code-block:: cpp

    #include "....cuh"              // filename

4. Add an if branch in 3 CUDA global functions in the file cuda_kernels.cu_

    .. code-block:: cuda

        __global__ void cuda_calculate_chi_squares(
        .
        .
        .
        if (estimator_id == LSE)
        {
            calculate_chi_square_lse(
                shared_chi_square,
                point_index,
                current_data,
                current_value,
                current_weight,
                current_state,
                user_info,
                user_info_size);
        }
        .
        .
        .
        else if (estimator_id == ...)   // estimator ID
        {
            ...(                        // function name Chi-square
                shared_chi_square,
                point_index,
                current_data,
                current_value,
                current_weight,
                current_state,
                user_info,
                user_info_size);
        }
        .
        .
        .


    .. code-block:: cuda

        __global__ void cuda_calculate_gradients(
        .
        .
        .
        if (estimator_id == LSE)
        {
            calculate_gradient_lse(
                shared_gradient,
                point_index,
                derivative_index,
                current_data,
                current_value,
                current_derivative,
                current_weight,
                user_info,
                user_info_size);
        }
        .
        .
        .
        else if (estimator_id == ...)   // estimator ID
        {
            ...(                        // function name gradient
                shared_gradient,
                point_index,
                derivative_index,
                current_data,
                current_value,
                current_derivative,
                current_weight,
                user_info,
                user_info_size);
        }
        .
        .
        .

    .. code-block:: cuda

        __global__ void cuda_calculate_hessians(
        .
        .
        .
        if (estimator_id == LSE)
        {
            calculate_hessian_lse(
                &sum,
                point_index,
                derivative_index_i + point_index,
                derivative_index_j + point_index,
                current_data,
                current_value,
                current_derivative,
                current_weight,
                user_info,
                user_info_size);
        }
        .
        .
        .
        else if (estimator_id == ...)   // estimator ID
        {
            ...(                        // function name hessian
                &sum,
                point_index,
                derivative_index_i + point_index,
                derivative_index_j + point_index,
                current_data,
                current_value,
                current_derivative,
                current_weight,
                user_info,
                user_info_size);
        }
        .
        .
        .
		
Future releases
---------------

A disadvantage of the Gpufit library, when compared with established CPU-based curve fitting packages, 
is that in order to add or modify a fit model function or a fit estimator, the library must be recompiled.  
We anticipate that this limitation can be overcome in future releases of the library, by employing 
run-time compilation of the CUDA code.
